#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C exception it raises into an
/// `NSError` (domain `ObjCException`). AVAudioEngine reports misconfiguration
/// — a stale tap format after a route change, a tap installed twice — by
/// raising, which Swift can't catch; this wrapper turns such crashes into
/// recoverable errors.
BOOL AVObjCTry(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
