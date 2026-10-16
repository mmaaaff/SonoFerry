#pragma once
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

static inline BOOL ClassicIsConnected(IOBluetoothDevice *device) {
#if !defined(SONOFERRY_PUBLIC_APIS_ONLY)
    SEL peerSelector = NSSelectorFromString(@"classicPeer");
    SEL stateSelector = NSSelectorFromString(@"state");
    if ([device respondsToSelector:peerSelector]) {
        id (*getPeer)(id, SEL) = (void *)[device methodForSelector:peerSelector];
        id peer = getPeer(device, peerSelector);
        if (!peer) return NO;
        if ([peer respondsToSelector:stateSelector]) {
            NSInteger (*getState)(id, SEL) = (void *)[peer methodForSelector:stateSelector];
            return getState(peer, stateSelector) == 2;
        }
    }
#endif
    return device.isConnected;
}
