//
//  CloudKitExceptionCatcher.h
//  FieldForge
//
//  CKContainer(identifier:) raises NSException (not a Swift Error) when the
//  container id is missing from entitlements. Swift cannot catch that. This
//  is the only launch-safe way to stay local instead of crashing.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. Returns YES on success. On NSException, fills `error` and
/// returns NO. Never used from App.init — CloudKit is created lazily.
BOOL FFCatchException(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
