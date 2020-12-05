// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import <OCMock/OCMock.h>
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import <FBSDKCoreKit/FBSDKCoreKit.h>

#import "FBSDKLoginManager.h"
#import "FBSDKLoginManager+Internal.h"
#import "FBSDKLoginManagerLoginResult.h"
#import "FBSDKLoginUtilityTests.h"

static NSString *const kFakeAppID = @"7391628439";

static NSString *const kFakeChallenge = @"a =bcdef";

static NSString *const kFakeNonce = @"fedcb =a";

@interface FBSDKLoginManager (Testing)

- (NSDictionary *)logInParametersFromURL:(NSURL *)url;

- (NSString *)loadExpectedNonce;

- (void)storeExpectedNonce:(NSString *)nonceExpected keychainStore:(FBSDKKeychainStore *)keychainStore;

@end

@interface FBSDKAuthenticationToken (Testing)

+ (void)setSkipSignatureVerification:(BOOL)value;

@end

@interface FBSDKLoginManagerTests : XCTestCase

@end

@implementation FBSDKLoginManagerTests
{
  id _mockNSBundle;
  id _mockInternalUtility;
  id _mockLoginManager;
  id _mockAccessTokenClass;
  id _mockAuthenticationTokenClass;
  id _mockProfileClass;
}

- (void)setUp
{
  [super setUp];
  _mockNSBundle = [FBSDKLoginUtilityTests mainBundleMock];
  [FBSDKSettings setAppID:kFakeAppID];
  [FBSDKAuthenticationToken setCurrentAuthenticationToken:nil];
  [FBSDKProfile setCurrentProfile:nil];
  [FBSDKAccessToken setCurrentAccessToken:nil];

  _mockInternalUtility = OCMClassMock(FBSDKInternalUtility.class);
  OCMStub(ClassMethod([_mockInternalUtility validateURLSchemes]));

  _mockLoginManager = OCMPartialMock([FBSDKLoginManager new]);
  OCMStub([_mockLoginManager loadExpectedChallenge]).andReturn(kFakeChallenge);
  OCMStub([_mockLoginManager loadExpectedNonce]).andReturn(kFakeNonce);

  _mockAccessTokenClass = OCMClassMock(FBSDKAccessToken.class);
  _mockAuthenticationTokenClass = OCMClassMock(FBSDKAuthenticationToken.class);
  _mockProfileClass = OCMClassMock(FBSDKProfile.class);
}

- (void)tearDown
{
  [super tearDown];

  [_mockInternalUtility stopMocking];
  _mockInternalUtility = nil;

  [_mockLoginManager stopMocking];
  _mockLoginManager = nil;

  [_mockAccessTokenClass stopMocking];
  _mockAccessTokenClass = nil;

  [_mockAuthenticationTokenClass stopMocking];
  _mockAuthenticationTokenClass = nil;

  [_mockProfileClass stopMocking];
  _mockProfileClass = nil;
}

- (NSURL *)authorizeURLWithParameters:(NSString *)parameters joinedBy:(NSString *)joinChar
{
  return [NSURL URLWithString:[NSString stringWithFormat:@"fb%@://authorize/%@%@", kFakeAppID, joinChar, parameters]];
}

- (NSURL *)authorizeURLWithFragment:(NSString *)fragment challenge:(NSString *)challenge
{
  challenge = [FBSDKUtility URLEncode:challenge];
  fragment = [NSString stringWithFormat:@"%@%@state=%@",
              fragment,
              fragment.length > 0 ? @"&" : @"",
              [FBSDKUtility URLEncode:[NSString stringWithFormat:@"{\"challenge\":\"%@\"}", challenge]]
  ];
  return [self authorizeURLWithParameters:fragment joinedBy:@"#"];
}

- (NSURL *)authorizeURLWithFragment:(NSString *)fragment
{
  return [self authorizeURLWithFragment:fragment challenge:kFakeChallenge];
}

// verify basic case of first login and getting granted and declined permissions (is not classified as cancelled)
- (void)testOpenURLAuth
{
  XCTestExpectation *expectation = [self expectationWithDescription:@"completed auth"];
  NSURL *url = [self authorizeURLWithFragment:@"granted_scopes=public_profile&denied_scopes=email%2Cuser_friends&signed_request=ggarbage.eyJhbGdvcml0aG0iOiJITUFDSEEyNTYiLCJjb2RlIjoid2h5bm90IiwiaXNzdWVkX2F0IjoxNDIyNTAyMDkyLCJ1c2VyX2lkIjoiMTIzIn0&access_token=sometoken&expires_in=5183949"];
  FBSDKLoginManager *target = _mockLoginManager;
  [target setRequestedPermissions:[NSSet setWithObjects:@"email", @"user_friends", nil]];
  __block FBSDKAccessToken *tokenAfterAuth;
  [target setHandler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    XCTAssertFalse(result.isCancelled);
    tokenAfterAuth = [FBSDKAccessToken currentAccessToken];
    XCTAssertEqualObjects(tokenAfterAuth, result.token);
    XCTAssertTrue([tokenAfterAuth.userID isEqualToString:@"123"], @"failed to parse userID");
    XCTAssertTrue([tokenAfterAuth.permissions isEqualToSet:[NSSet setWithObject:@"public_profile"]], @"unexpected permissions");
    XCTAssertTrue([result.grantedPermissions isEqualToSet:[NSSet setWithObject:@"public_profile"]], @"unexpected permissions");
    NSSet *expectedDeclined = [NSSet setWithObjects:@"email", @"user_friends", nil];
    XCTAssertEqualObjects(tokenAfterAuth.declinedPermissions, expectedDeclined, @"unexpected permissions");
    XCTAssertEqualObjects(result.declinedPermissions, expectedDeclined, @"unexpected permissions");
    [expectation fulfill];
  }];

  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);

  [self waitForExpectationsWithTimeout:3 handler:^(NSError *error) {
    XCTAssertNil(error);
  }];

  // now test a cancel and make sure the current token is not touched.
  url = [self authorizeURLWithParameters:@"error=access_denied&error_code=200&error_description=Permissions+error&error_reason=user_denied#_=_" joinedBy:@"?"];
  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);
  FBSDKAccessToken *actualTokenAfterCancel = [FBSDKAccessToken currentAccessToken];
  XCTAssertEqualObjects(tokenAfterAuth, actualTokenAfterCancel);
}

// verify basic case of first login and no declined permissions.
- (void)testOpenURLAuthNoDeclines
{
  NSURL *url = [self authorizeURLWithFragment:@"granted_scopes=public_profile&denied_scopes=&signed_request=ggarbage.eyJhbGdvcml0aG0iOiJITUFDSEEyNTYiLCJjb2RlIjoid2h5bm90IiwiaXNzdWVkX2F0IjoxNDIyNTAyMDkyLCJ1c2VyX2lkIjoiMTIzIn0&access_token=sometoken&expires_in=5183949"];
  FBSDKLoginManager *target = _mockLoginManager;
  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);
  FBSDKAccessToken *actualToken = [FBSDKAccessToken currentAccessToken];
  XCTAssertTrue([actualToken.userID isEqualToString:@"123"], @"failed to parse userID");
  XCTAssertTrue([actualToken.permissions isEqualToSet:[NSSet setWithObject:@"public_profile"]], @"unexpected permissions");
  NSSet *expectedDeclined = [NSSet set];
  XCTAssertEqualObjects(actualToken.declinedPermissions, expectedDeclined, @"unexpected permissions");
}

// verify that recentlyDeclined is a subset of requestedPermissions (i.e., other declined permissions are not in recentlyDeclined)
- (void)testOpenURLRecentlyDeclined
{
  XCTestExpectation *expectation = [self expectationWithDescription:@"completed auth"];
  // receive url with denied_scopes more than what was requested.
  NSURL *url = [self authorizeURLWithFragment:@"granted_scopes=public_profile&denied_scopes=user_friends,user_likes&signed_request=ggarbage.eyJhbGdvcml0aG0iOiJITUFDSEEyNTYiLCJjb2RlIjoid2h5bm90IiwiaXNzdWVkX2F0IjoxNDIyNTAyMDkyLCJ1c2VyX2lkIjoiMTIzIn0&access_token=sometoken&expires_in=5183949"];

  FBSDKLoginManagerLoginResultBlock handler = ^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    XCTAssertFalse(result.isCancelled);
    XCTAssertEqualObjects(result.declinedPermissions, [NSSet setWithObject:@"user_friends"]);
    NSSet *expectedDeclinedPermissions = [NSSet setWithObjects:@"user_friends", @"user_likes", nil];
    XCTAssertEqualObjects(result.token.declinedPermissions, expectedDeclinedPermissions);
    XCTAssertEqualObjects(result.grantedPermissions, [NSSet setWithObject:@"public_profile"]);
    [expectation fulfill];
  };
  FBSDKLoginManager *target = _mockLoginManager;
  [target setRequestedPermissions:[NSSet setWithObject:@"user_friends"]];
  [target setHandler:handler];
  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);
  [self waitForExpectationsWithTimeout:3 handler:^(NSError *error) {
    XCTAssertNil(error);
  }];
}

// verify that a reauth for already granted permissions is not treated as a cancellation.
- (void)testOpenURLReauthSamePermissionsIsNotCancelled
{
  // XCTestExpectation *expectation = [self expectationWithDescription:@"completed reauth"];
  // set up a current token with public_profile
  FBSDKAccessToken *existingToken = [[FBSDKAccessToken alloc] initWithTokenString:@"token"
                                                                      permissions:@[@"public_profile", @"read_stream"]
                                                              declinedPermissions:@[]
                                                               expiredPermissions:@[]
                                                                            appID:@""
                                                                           userID:@""
                                                                   expirationDate:nil
                                                                      refreshDate:nil
                                                         dataAccessExpirationDate:nil];
  [FBSDKAccessToken setCurrentAccessToken:existingToken];
  NSURL *url = [self authorizeURLWithFragment:@"granted_scopes=public_profile,read_stream&denied_scopes=email%2Cuser_friends&signed_request=ggarbage.eyJhbGdvcml0aG0iOiJITUFDSEEyNTYiLCJjb2RlIjoid2h5bm90IiwiaXNzdWVkX2F0IjoxNDIyNTAyMDkyLCJ1c2VyX2lkIjoiMTIzIn0&access_token=sometoken&expires_in=5183949"];
  // Use OCMock to verify the validateReauthentication: call and verify the result there.
  id target = _mockLoginManager;
  [[[target stub] andDo:^(NSInvocation *invocation) {
    __unsafe_unretained FBSDKLoginManagerLoginResult *result;
    [invocation getArgument:&result atIndex:3];
    XCTAssertFalse(result.isCancelled);
    XCTAssertNotNil(result.token);
  }] validateReauthentication:[OCMArg any] withResult:[OCMArg any]];

  [target setRequestedPermissions:[NSSet setWithObjects:@"public_profile", @"read_stream", nil]];

  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wnonnull"

  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);

  #pragma clang diagnostic pop

  [target verify];
}

// verify that a reauth for already granted permissions is not treated as a cancellation.
- (void)testOpenURLReauthNoPermissionsIsNotCancelled
{
  // XCTestExpectation *expectation = [self expectationWithDescription:@"completed reauth"];
  // set up a current token with public_profile
  FBSDKAccessToken *existingToken = [[FBSDKAccessToken alloc] initWithTokenString:@"token"
                                                                      permissions:@[@"public_profile", @"read_stream"]
                                                              declinedPermissions:@[]
                                                               expiredPermissions:@[]
                                                                            appID:@""
                                                                           userID:@""
                                                                   expirationDate:nil
                                                                      refreshDate:nil
                                                         dataAccessExpirationDate:nil];
  [FBSDKAccessToken setCurrentAccessToken:existingToken];
  NSURL *url = [self authorizeURLWithFragment:@"granted_scopes=public_profile,read_stream&denied_scopes=email%2Cuser_friends&signed_request=ggarbage.eyJhbGdvcml0aG0iOiJITUFDSEEyNTYiLCJjb2RlIjoid2h5bm90IiwiaXNzdWVkX2F0IjoxNDIyNTAyMDkyLCJ1c2VyX2lkIjoiMTIzIn0&access_token=sometoken&expires_in=5183949"];
  // Use OCMock to verify the validateReauthentication: call and verify the result there.
  id target = _mockLoginManager;
  [[[target stub] andDo:^(NSInvocation *invocation) {
    __unsafe_unretained FBSDKLoginManagerLoginResult *result;
    [invocation getArgument:&result atIndex:3];
    XCTAssertFalse(result.isCancelled);
    XCTAssertNotNil(result.token);
  }] validateReauthentication:[OCMArg any] withResult:[OCMArg any]];

  [(FBSDKLoginManager *)target setRequestedPermissions:nil];

  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wnonnull"

  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);

  #pragma clang diagnostic pop

  [target verify];
}

- (void)testOpenURLWithBadChallenge
{
  XCTestExpectation *expectation = [self expectationWithDescription:@"completed auth"];
  NSURL *url = [self authorizeURLWithFragment:@"granted_scopes=public_profile&denied_scopes=email%2Cuser_friends&signed_request=ggarbage.eyJhbGdvcml0aG0iOiJITUFDSEEyNTYiLCJjb2RlIjoid2h5bm90IiwiaXNzdWVkX2F0IjoxNDIyNTAyMDkyLCJ1c2VyX2lkIjoiMTIzIn0&access_token=sometoken&expires_in=5183949"
                                    challenge:@"someotherchallenge"];
  FBSDKLoginManager *target = _mockLoginManager;
  [target setRequestedPermissions:[NSSet setWithObjects:@"email", @"user_friends", nil]];
  [target setHandler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    XCTAssertNotNil(error);
    XCTAssertNil(result.token);
    [expectation fulfill];
  }];

  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);

  [self waitForExpectationsWithTimeout:3 handler:^(NSError *error) {
    XCTAssertNil(error);
  }];
}

- (void)testOpenURLWithNoChallengeAndError
{
  XCTestExpectation *expectation = [self expectationWithDescription:@"completed auth"];
  NSURL *url = [self authorizeURLWithParameters:@"error=some_error&error_code=999&error_message=Errorerror_reason=foo#_=_" joinedBy:@"?"];

  FBSDKLoginManager *target = _mockLoginManager;
  [target setRequestedPermissions:[NSSet setWithObjects:@"email", @"user_friends", nil]];
  [target setHandler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    XCTAssertNotNil(error);
    [expectation fulfill];
  }];

  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);

  [self waitForExpectationsWithTimeout:3 handler:^(NSError *error) {
    XCTAssertNil(error);
  }];
}

- (void)testOpenURLAuthWithIDToken
{
  XCTestExpectation *expectation = [self expectationWithDescription:self.name];
  FBSDKLoginManager *target = _mockLoginManager;
  [FBSDKAuthenticationToken setSkipSignatureVerification:YES];

  long currentTime = [[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] longValue];
  NSDictionary *expectedClaims = @{
    @"iss" : @"https://facebook.com/dialog/oauth",
    @"aud" : kFakeAppID,
    @"nonce" : kFakeNonce,
    @"exp" : @(currentTime + 60 * 60 * 48), // 2 days later
    @"iat" : @(currentTime - 60), // 1 min ago
    @"sub" : @"1234",
    @"name" : @"Test User",
    @"picture" : @"https://www.facebook.com/some_picture",
  };
  NSData *expectedClaimsData = [FBSDKTypeUtility dataWithJSONObject:expectedClaims options:0 error:nil];
  NSString *encodedClaims = [FBSDKBase64 encodeData:expectedClaimsData];
  NSDictionary *expectedHeader = @{
    @"alg" : @"RS256",
    @"typ" : @"JWT"
  };
  NSData *expectedHeaderData = [FBSDKTypeUtility dataWithJSONObject:expectedHeader options:0 error:nil];
  NSString *encodedHeader = [FBSDKBase64 encodeData:expectedHeaderData];

  NSString *tokenString = [NSString stringWithFormat:@"%@.%@.%@", encodedHeader, encodedClaims, @"signature"];
  NSURL *url = [self authorizeURLWithFragment:[NSString stringWithFormat:@"id_token=%@", tokenString] challenge:kFakeChallenge];

  [target setHandler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    // XCTAssertFalse(result.isCancelled);

    FBSDKAuthenticationToken *authToken = FBSDKAuthenticationToken.currentAuthenticationToken;
    XCTAssertNotNil(authToken, @"An Authentication token should be created after successful login");
    XCTAssertEqualObjects(authToken.tokenString, tokenString, @"A raw authentication token string should be stored");
    XCTAssertEqualObjects(authToken.nonce, kFakeNonce, @"The nonce claims in the authentication token should be stored");

    FBSDKProfile *profile = [FBSDKProfile currentProfile];
    XCTAssertNotNil(profile, @"user profile should be updated");
    XCTAssertEqualObjects(profile.name, expectedClaims[@"name"], @"failed to parse user name");
    XCTAssertEqualObjects(profile.userID, expectedClaims[@"sub"], @"failed to parse userID");
    XCTAssertEqualObjects(profile.imageURL.absoluteString, expectedClaims[@"picture"], @"failed to parse user profile picture");

    [expectation fulfill];
  }];

  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);

  [self waitForExpectationsWithTimeout:3 handler:^(NSError *error) {
    XCTAssertNil(error);
  }];

  [FBSDKAuthenticationToken setSkipSignatureVerification:NO];
}

- (void)testOpenURLAuthWithInvalidIDToken
{
  XCTestExpectation *expectation = [self expectationWithDescription:self.name];
  FBSDKLoginManager *target = _mockLoginManager;
  NSURL *url = [self authorizeURLWithFragment:@"id_token=invalid_token" challenge:kFakeChallenge];

  [target setHandler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    XCTAssertNotNil(error);
    OCMReject([self->_mockAccessTokenClass setCurrentAccessToken:OCMOCK_ANY]);
    OCMReject([self->_mockAuthenticationTokenClass setCurrentAuthenticationToken:OCMOCK_ANY]);
    OCMReject([self->_mockProfileClass setCurrentProfile:OCMOCK_ANY]);
    [expectation fulfill];
  }];

  XCTAssertTrue([target application:nil openURL:url sourceApplication:@"com.apple.mobilesafari" annotation:nil]);

  [self waitForExpectationsWithTimeout:3 handler:^(NSError *error) {
    XCTAssertNil(error);
  }];
}

- (void)testLoginManagerRetainsItselfForLoginMethod
{
  // Mock some methods to force an error callback.
  [[[_mockInternalUtility stub] andReturnValue:@NO] isFacebookAppInstalled];
  NSError *URLError = [[NSError alloc] initWithDomain:FBSDKErrorDomain code:0 userInfo:nil];
  [[_mockInternalUtility stub] appURLWithHost:OCMOCK_ANY
                                         path:OCMOCK_ANY
                              queryParameters:OCMOCK_ANY
                                        error:((NSError __autoreleasing **)[OCMArg setTo:URLError])];

  XCTestExpectation *expectation = [self expectationWithDescription:@"completed auth"];
  FBSDKLoginManager *manager = [FBSDKLoginManager new];
  [manager logInWithPermissions:@[@"public_profile"] fromViewController:nil handler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    [expectation fulfill];
  }];
  // This makes sure that FBSDKLoginManager is retaining itself for the duration of the call
  manager = nil;
  [self waitForExpectationsWithTimeout:5 handler:^(NSError *_Nullable error) {
    XCTAssertNil(error);
  }];
}

- (void)testCallingLoginWhileAnotherLoginHasNotFinishedNoOps
{
  // Mock some methods to force a SafariVC load
  [[[_mockInternalUtility stub] andReturnValue:@NO] isFacebookAppInstalled];

  __block int loginCount = 0;
  FBSDKLoginManager *manager = _mockLoginManager;
  [[[(id)manager stub] andDo:^(NSInvocation *invocation) {
    loginCount++;
  }] logIn];
  [manager logInWithPermissions:@[@"public_profile"] fromViewController:nil handler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    // This will never be called
    XCTFail(@"Should not be called");
  }];

  [manager logInWithPermissions:@[@"public_profile"] fromViewController:nil handler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    // This will never be called
    XCTFail(@"Should not be called");
  }];

  XCTAssertEqual(loginCount, 1);
}

- (void)testBetaLoginExperienceEnabledLoginParams
{
  FBSDKLoginConfiguration *config = [[FBSDKLoginConfiguration alloc]
                                     initWithPermissions:@[@"public_profile", @"email"]
                                     betaLoginExperience:FBSDKBetaLoginExperienceEnabled];

  NSDictionary *params = [_mockLoginManager logInParametersWithConfiguration:config serverConfiguration:nil];
  [self validateCommonLoginParameters:params];
  // TODO: Re-implement when server issue resolved - T80884847
  // XCTAssertEqualObjects(params[@"response_type"], @"id_token,token_or_nonce,signed_request,graph_domain");
  XCTAssertEqualObjects(params[@"response_type"], @"token_or_nonce,signed_request,graph_domain");
  // TODO: Re-implement when server issue resolved - T80884847
  // XCTAssertEqualObjects(params[@"scope"], @"public_profile,email,openid");
  XCTAssertEqualObjects(params[@"scope"], @"public_profile,email");
  XCTAssertNotNil(params[@"nonce"]);
}

- (void)testBetaLoginExperienceRestrictedLoginParams
{
  FBSDKLoginConfiguration *config = [[FBSDKLoginConfiguration alloc]
                                     initWithPermissions:@[@"public_profile", @"email"]
                                     betaLoginExperience:FBSDKBetaLoginExperienceRestricted
                                     nonce:@"some_nonce"];

  NSDictionary *params = [_mockLoginManager logInParametersWithConfiguration:config serverConfiguration:nil];
  [self validateCommonLoginParameters:params];
  XCTAssertEqualObjects(params[@"response_type"], @"id_token");
  // TODO: Re-implement when server issue resolved - T80884847
  // XCTAssertEqualObjects(params[@"scope"], @"public_profile,email,openid");
  XCTAssertEqualObjects(params[@"scope"], @"public_profile,email");
  XCTAssertEqualObjects(params[@"nonce"], @"some_nonce");
}

- (void)testlogInParametersFromURL
{
  NSURL *url = [NSURL URLWithString:@"myapp://somelink/?al_applink_data=%7B%22target_url%22%3Anull%2C%22extras%22%3A%7B%22fb_login%22%3A%22%7B%5C%22granted_scopes%5C%22%3A%5C%22public_profile%5C%22%2C%5C%22denied_scopes%5C%22%3A%5C%22%5C%22%2C%5C%22signed_request%5C%22%3A%5C%22ggarbage.eyJhbGdvcml0aG0iOiJITUFDSEEyNTYiLCJjb2RlIjoid2h5bm90IiwiaXNzdWVkX2F0IjoxNDIyNTAyMDkyLCJ1c2VyX2lkIjoiMTIzIn0%5C%22%2C%5C%22nonce%5C%22%3A%5C%22someNonce%5C%22%2C%5C%22data_access_expiration_time%5C%22%3A%5C%221607374566%5C%22%2C%5C%22expires_in%5C%22%3A%5C%225183401%5C%22%7D%22%7D%2C%22referer_app_link%22%3A%7B%22url%22%3A%22fb%3A%5C%2F%5C%2F%5C%2F%22%2C%22app_name%22%3A%22Facebook%22%7D%7D"];

  NSDictionary *params = [_mockLoginManager logInParametersFromURL:url];

  XCTAssertNotNil(params);
  XCTAssertEqualObjects(params[@"nonce"], @"someNonce");
  XCTAssertEqualObjects(params[@"granted_scopes"], @"public_profile");
  XCTAssertEqualObjects(params[@"denied_scopes"], @"");
}

- (void)testLogInWithURLFailWithInvalidLoginData
{
  XCTestExpectation *expectation = [self expectationWithDescription:self.name];
  NSURL *urlWithInvalidLoginData = [NSURL URLWithString:@"myapp://somelink/?al_applink_data=%7B%22target_url%22%3Anull%2C%22extras%22%3A%7B%22fb_login%22%3A%22invalid%22%7D%2C%22referer_app_link%22%3A%7B%22url%22%3A%22fb%3A%5C%2F%5C%2F%5C%2F%22%2C%22app_name%22%3A%22Facebook%22%7D%7D"];
  FBSDKLoginManagerLoginResultBlock handler = ^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    if (error) {
      XCTAssertNil(result);
      [expectation fulfill];
    } else {
      XCTFail(@"Should have error");
    }
  };

  [_mockLoginManager logInWithURL:urlWithInvalidLoginData handler:handler];

  [self waitForExpectationsWithTimeout:1 handler:^(NSError *_Nullable error) {
    XCTAssertNil(error);
  }];
}

- (void)testLogInWithURLFailWithNoLoginData
{
  XCTestExpectation *expectation = [self expectationWithDescription:self.name];
  NSURL *urlWithNoLoginData = [NSURL URLWithString:@"myapp://somelink/?al_applink_data=%7B%22target_url%22%3Anull%2C%22extras%22%3A%7B%22some_param%22%3A%22some_value%22%7D%2C%22referer_app_link%22%3A%7B%22url%22%3A%22fb%3A%5C%2F%5C%2F%5C%2F%22%2C%22app_name%22%3A%22Facebook%22%7D%7D"];
  FBSDKLoginManagerLoginResultBlock handler = ^(FBSDKLoginManagerLoginResult *result, NSError *error) {
    if (error) {
      XCTAssertNil(result);
      [expectation fulfill];
    } else {
      XCTFail(@"Should have error");
    }
  };

  [_mockLoginManager logInWithURL:urlWithNoLoginData handler:handler];

  [self waitForExpectationsWithTimeout:1 handler:^(NSError *_Nullable error) {
    XCTAssertNil(error);
  }];
}

- (void)testLogout
{
  [_mockLoginManager logOut];

  OCMVerify(ClassMethod([_mockAccessTokenClass setCurrentAccessToken:nil]));
  OCMVerify(ClassMethod([_mockAuthenticationTokenClass setCurrentAuthenticationToken:nil]));
  OCMVerify(ClassMethod([_mockProfileClass setCurrentProfile:nil]));
}

- (void)testStoreExpectedNonce
{
  FBSDKKeychainStore *keychainStore = [[FBSDKKeychainStore alloc] initWithService:self.name accessGroup:nil];

  [_mockLoginManager storeExpectedNonce:@"some_nonce" keychainStore:keychainStore];

  XCTAssertEqualObjects([keychainStore stringForKey:@"expected_login_nonce"], @"some_nonce");
}

- (void)validateCommonLoginParameters:(NSDictionary *)params
{
  XCTAssertEqualObjects(params[@"client_id"], kFakeAppID);
  XCTAssertEqualObjects(params[@"redirect_uri"], @"fbconnect://success");
  XCTAssertEqualObjects(params[@"display"], @"touch");
  XCTAssertEqualObjects(params[@"sdk"], @"ios");
  XCTAssertEqualObjects(params[@"return_scopes"], @"true");
  XCTAssertEqual(params[@"auth_type"], FBSDKLoginAuthTypeRerequest);
  XCTAssertEqualObjects(params[@"fbapp_pres"], @0);
  XCTAssertEqualObjects(params[@"ies"], [FBSDKSettings isAutoLogAppEventsEnabled] ? @1 : @0);

  long long cbt = [params[@"cbt"] longLongValue];
  long long currentMilliseconds = round(1000 * [NSDate date].timeIntervalSince1970);
  XCTAssertEqualWithAccuracy(cbt, currentMilliseconds, 500);
}

@end
