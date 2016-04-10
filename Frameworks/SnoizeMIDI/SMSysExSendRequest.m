/*
 Copyright (c) 2001-2008, Kurt Revis.  All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


#import "SMSysExSendRequest.h"

#import "SMClient.h"
#import "SMEndpoint.h"
#import "SMSystemExclusiveMessage.h"
#import "SMUtilities.h"


#define USE_CUSTOM_SYSEX_SENDER 1

#if USE_CUSTOM_SYSEX_SENDER

// MIDI-OX default settings:
// 256 byte buffers
// Delay 60 ms between buffers
// (also: Delay 60 ms after F7)
#define BUFFER_SIZE 256
#define BUFFER_DELAY_MS 60

// at 3125 bytes/sec, sending 256 bytes = 0.0819 sec
// then pause 60 ms additional          = 0.0600 sec
// so total time:  256 bytes / 0.1419 sec = 1804 bytes/sec = 57% of normal speed

static void SendNextBytes(MIDISysexSendRequest *request, MIDIPortRef port, MIDIPacketList *packetList, const Byte *dataEnd, dispatch_queue_t queue)
{
    size_t packetBytes = MIN(BUFFER_SIZE, request->bytesToSend);
    packetList->packet[0].length = packetBytes;
    memcpy(packetList->packet[0].data, dataEnd - request->bytesToSend, packetBytes);

    MIDISend(port, request->destination, packetList);

    request->bytesToSend -= packetBytes;
    if (request->bytesToSend == 0) {
        request->complete = 1;
    }

    if (!request->complete) {
        dispatch_time_t nextTime = dispatch_time(DISPATCH_TIME_NOW, BUFFER_DELAY_MS * NSEC_PER_MSEC);
        dispatch_after(nextTime, queue, ^{
            SendNextBytes(request, port, packetList, dataEnd, queue);
        });
    }
    else {
        if (request->completionProc) {
            request->completionProc(request);
        }

        MIDIPortDispose(port);
        free(packetList);
        dispatch_release(queue);
    }
}

static OSStatus CustomMIDISendSysex(MIDISysexSendRequest *request) {
    if (!request || !request->destination || !request->data) {
        return -50; // paramErr
    }

    if (request->bytesToSend == 0) {
        request->complete = 1;
    }

    if (request->complete) {
        if (request->completionProc) {
            request->completionProc(request);
        }
        return 0;   // noErr
    }

    MIDIPortRef port;
    OSStatus status = MIDIOutputPortCreate([[SMClient sharedClient] midiClient], CFSTR("CustomMIDISendSysex"), &port);
    if (status != 0) {
        return status;
    }

    size_t packetListSize = BUFFER_SIZE + offsetof(MIDIPacket, data) + offsetof(MIDIPacketList, packet);
    MIDIPacketList *packetList = calloc(1, packetListSize);
    if (!packetList) {
        return -41; // mFulErr
    }
    packetList->numPackets = 1;
    packetList->packet[0].timeStamp = 0;

    const Byte *dataEnd = request->data + request->bytesToSend;

    dispatch_queue_t queue = dispatch_queue_create("com.snoize.SnoizeMIDI.CustomMIDISendSysex", DISPATCH_QUEUE_SERIAL);
    if (!queue) {
        return -41; // mFulErr
    }
    dispatch_set_target_queue(queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));

    dispatch_async(queue, ^{
        SendNextBytes(request, port, packetList, dataEnd, queue);
    });

    return 0;   // noErr
}

#endif


@interface SMSysExSendRequest (Private)

static void completionProc(MIDISysexSendRequest *request);
- (void)completionProc;

@end


@implementation SMSysExSendRequest

NSString *SMSysExSendRequestFinishedNotification = @"SMSysExSendRequestFinishedNotification";

+ (SMSysExSendRequest *)sysExSendRequestWithMessage:(SMSystemExclusiveMessage *)aMessage endpoint:(SMDestinationEndpoint *)endpoint;
{
    return [[[self alloc] initWithMessage:aMessage endpoint:endpoint] autorelease];
}

- (id)initWithMessage:(SMSystemExclusiveMessage *)aMessage endpoint:(SMDestinationEndpoint *)endpoint;
{
    if (!(self = [super init]))
        return nil;

    SMAssert(aMessage != nil);

    message = [aMessage retain];
    fullMessageData = [[message fullMessageData] retain];

    // MIDISysexSendRequest length is "only" a UInt32
    if ([fullMessageData length] > UINT32_MAX) {
        [self release];
        return nil;
    }

    request.destination = [endpoint endpointRef];
    request.data = (Byte *)[fullMessageData bytes];
    request.bytesToSend = (UInt32)[fullMessageData length];
    request.complete = FALSE;
    request.completionProc = completionProc;
    request.completionRefCon = self;

    return self;
}

- (id)init;
{
    SMRejectUnusedImplementation(self, _cmd);
    return nil;
}

- (void)dealloc
{
    [message release];
    message = nil;
    [fullMessageData release];
    fullMessageData = nil;

    [super dealloc];
}

- (SMSystemExclusiveMessage *)message;
{
    return message;
}

- (void)send;
{
    OSStatus status;

    // Retain ourself, so we are guaranteed to stick around while the send is happening.
    // When we are notified that the request is finished, we will release ourself.
    [self retain];

#if USE_CUSTOM_SYSEX_SENDER
    status = CustomMIDISendSysex(&request);
#else
    status = MIDISendSysex(&request);
#endif
    if (status) {
        NSLog(@"MIDISendSysex() returned error: %ld", (long)status);
        [self release];
    }
}

- (BOOL)cancel;
{
    if (request.complete)
        return NO;

    request.complete = TRUE;
    return YES;
}

- (UInt32)bytesRemaining;
{
    return request.bytesToSend;
}

- (UInt32)totalBytes;
{
    return (UInt32)[fullMessageData length];
}

- (UInt32)bytesSent;
{
    UInt32 totalBytes, bytesRemaining;

    totalBytes = [self totalBytes];
    bytesRemaining = [self bytesRemaining];
    SMAssert(totalBytes >= bytesRemaining);

    return totalBytes - bytesRemaining;
}

- (BOOL)wereAllBytesSent;
{
    return ([self bytesRemaining] == 0);
}

@end


@implementation SMSysExSendRequest (Private)

static void completionProc(MIDISysexSendRequest *request)
{
    // NOTE: This is called on CoreMIDI's sysex sending thread.
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];    

    SMSysExSendRequest *requestObj = (SMSysExSendRequest *)(request->completionRefCon);
    [requestObj performSelectorOnMainThread:@selector(completionProc) withObject:nil waitUntilDone:NO];

    [pool release];
}

- (void)completionProc;
{
    [[NSNotificationCenter defaultCenter] postNotificationName:SMSysExSendRequestFinishedNotification object:self];
    [self release];
}

@end
