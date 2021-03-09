import 'dart:async';

import 'package:aqueduct/src/openapi/openapi.dart';
import 'package:crypto/crypto.dart';

import 'package:aqueduct/src/openapi/documentable.dart';
import '../utilities/token_generator.dart';
import 'auth.dart';

/// A OAuth 2.0 authorization server.
///
/// An [AuthServer] is an implementation of an OAuth 2.0 authorization server. An authorization server
/// issues, refreshes and revokes access tokens. It also verifies previously issued tokens, as
/// well as client and resource owner credentials.
///
/// [AuthServer]s are typically used in conjunction with [AuthController] and [AuthRedirectController].
/// These controllers provide HTTP interfaces to the [AuthServer] for issuing and refreshing tokens.
/// Likewise, [Authorizer]s verify these issued tokens to protect endpoint controllers.
///
/// [AuthServer]s can be customized through their [delegate]. This required property manages persistent storage of authorization
/// objects among other tasks. There are security considerations for [AuthServerDelegate] implementations; prefer to use a tested
/// implementation like `ManagedAuthDelegate` from `package:aqueduct/managed_auth.dart`.
///
/// Usage example with `ManagedAuthDelegate`:
///
///         import 'package:aqueduct/aqueduct.dart';
///         import 'package:aqueduct/managed_auth.dart';
///
///         class User extends ManagedObject<_User> implements _User, ManagedAuthResourceOwner {}
///         class _User extends ManagedAuthenticatable {}
///
///         class Channel extends ApplicationChannel {
///           ManagedContext context;
///           AuthServer authServer;
///
///           @override
///           Future prepare() async {
///             context = createContext();
///
///             final delegate = ManagedAuthStorage<User>(context);
///             authServer = AuthServer(delegate);
///           }
///
///           @override
///           Controller get entryPoint {
///             final router = Router();
///             router
///               .route("/protected")
///               .link(() =>Authorizer(authServer))
///               .link(() => ProtectedResourceController());
///
///             router
///               .route("/auth/token")
///               .link(() => AuthController(authServer));
///
///             return router;
///           }
///         }
///
class AuthServer implements AuthValidator, APIComponentDocumenter {
  /// Creates a instance of an [AuthServer] with a [delegate].
  ///
  /// [hashFunction] defaults to [sha256].
  AuthServer(this.delegate,
      {this.hashRounds = 1000, this.hashLength = 32, Hash? hashFunction})
      : hashFunction = hashFunction ?? sha256;

  /// The object responsible for carrying out the storage mechanisms of this instance.
  ///
  /// This instance is responsible for storing, fetching and deleting instances of
  /// [AuthToken], [AuthCode] and [AuthClient] by implementing the [AuthServerDelegate] interface.
  ///
  /// It is preferable to use the implementation of [AuthServerDelegate] from 'package:aqueduct/managed_auth.dart'. See
  /// [AuthServer] for more details.
  final AuthServerDelegate delegate;

  /// The number of hashing rounds performed by this instance when validating a password.
  final int hashRounds;

  /// The resulting key length of a password hash when generated by this instance.
  final int hashLength;

  /// The [Hash] function used by the PBKDF2 algorithm to generate password hashes by this instance.
  final Hash hashFunction;

  /// Used during OpenAPI documentation.
  final APISecuritySchemeOAuth2Flow documentedAuthorizationCodeFlow =
      APISecuritySchemeOAuth2Flow.empty()..scopes = {};

  /// Used during OpenAPI documentation.
  final APISecuritySchemeOAuth2Flow documentedPasswordFlow =
      APISecuritySchemeOAuth2Flow.empty()..scopes = {};

  /// Used during OpenAPI documentation.
  final APISecuritySchemeOAuth2Flow documentedImplicitFlow =
      APISecuritySchemeOAuth2Flow.empty()..scopes = {};

  static const String tokenTypeBearer = "bearer";

  /// Hashes a [password] with [salt] using PBKDF2 algorithm.
  ///
  /// See [hashRounds], [hashLength] and [hashFunction] for more details. This method
  /// invoke [AuthUtility.generatePasswordHash] with the above inputs.
  String hashPassword(String password, String salt) {
    return AuthUtility.generatePasswordHash(password, salt,
        hashRounds: hashRounds,
        hashLength: hashLength,
        hashFunction: hashFunction);
  }

  /// Adds an OAuth2 client.
  ///
  /// [delegate] will store this client for future use.
  Future addClient(AuthClient client) async {
    if (client.redirectURI != null && client.hashedSecret == null) {
      throw ArgumentError(
          "A client with a redirectURI must have a client secret.");
    }

    return delegate.addClient(this, client);
  }

  /// Returns a [AuthClient] record for its [clientID].
  ///
  /// Returns null if none exists.
  Future<AuthClient?> getClient(String clientID) async {
    return delegate.getClient(this, clientID);
  }

  /// Revokes a [AuthClient] record.
  ///
  /// Removes cached occurrences of [AuthClient] for [clientID].
  /// Asks [delegate] to remove an [AuthClient] by its ID via [AuthServerDelegate.removeClient].
  Future removeClient(String? clientID) async {
    if (clientID == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    return delegate.removeClient(this, clientID);
  }

  /// Revokes access for an [ResourceOwner].
  ///
  /// All authorization codes and tokens for the [ResourceOwner] identified by [identifier]
  /// will be revoked.
  Future revokeAllGrantsForResourceOwner(int? identifier) async {
    if (identifier == null) {
      throw ArgumentError.notNull("identifier");
    }

    await delegate.removeTokens(this, identifier);
  }

  /// Authenticates a username and password of an [ResourceOwner] and returns an [AuthToken] upon success.
  ///
  /// This method works with this instance's [delegate] to generate and store a token if all credentials are correct.
  /// If credentials are not correct, it will throw the appropriate [AuthRequestError].
  ///
  /// After [expiration], this token will no longer be valid.
  Future<AuthToken> authenticate(String? username, String? password,
      String? clientID, String? clientSecret,
      {Duration expiration = const Duration(hours: 24),
      List<AuthScope>? requestedScopes}) async {
    if (clientID == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    final client = await getClient(clientID);
    if (client == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (username == null || password == null) {
      throw AuthServerException(AuthRequestError.invalidRequest, client);
    }

    if (client.isPublic) {
      if (!(clientSecret == null || clientSecret == "")) {
        throw AuthServerException(AuthRequestError.invalidClient, client);
      }
    } else {
      if (clientSecret == null) {
        throw AuthServerException(AuthRequestError.invalidClient, client);
      }

      if (client.hashedSecret != hashPassword(clientSecret, client.salt!)) {
        throw AuthServerException(AuthRequestError.invalidClient, client);
      }
    }

    final authenticatable = await delegate.getResourceOwner(this, username);
    if (authenticatable == null) {
      throw AuthServerException(AuthRequestError.invalidGrant, client);
    }

    final dbSalt = authenticatable.salt;
    final dbPassword = authenticatable.hashedPassword;
    final hash = hashPassword(password, dbSalt!);
    if (hash != dbPassword) {
      throw AuthServerException(AuthRequestError.invalidGrant, client);
    }

    final validScopes =
        _validatedScopes(client, authenticatable, requestedScopes);
    final token = _generateToken(
        authenticatable.id, client.id, expiration.inSeconds,
        allowRefresh: !client.isPublic, scopes: validScopes);
    await delegate.addToken(this, token);

    return token;
  }

  /// Returns a [Authorization] for [accessToken].
  ///
  /// This method obtains an [AuthToken] for [accessToken] from [delegate] and then verifies that the token is valid.
  /// If the token is valid, an [Authorization] object is returned. Otherwise, an [AuthServerException] is thrown.
  Future<Authorization> verify(String? accessToken,
      {List<AuthScope>? scopesRequired}) async {
    if (accessToken == null) {
      throw AuthServerException(AuthRequestError.invalidRequest, null);
    }

    final t = await delegate.getToken(this, byAccessToken: accessToken);
    if (t == null || t.isExpired) {
      throw AuthServerException(AuthRequestError.invalidGrant,
          AuthClient(t?.clientID ?? "", null, null));
    }

    if (scopesRequired != null) {
      if (!AuthScope.verify(scopesRequired, t.scopes)) {
        throw AuthServerException(
            AuthRequestError.invalidScope, AuthClient(t.clientID, null, null));
      }
    }

    return Authorization(t.clientID, t.resourceOwnerIdentifier, this,
        scopes: t.scopes);
  }

  /// Refreshes a valid [AuthToken] instance.
  ///
  /// This method will refresh a [AuthToken] given the [AuthToken]'s [refreshToken] for a given client ID.
  /// This method coordinates with this instance's [delegate] to update the old token with a access token and issue/expiration dates if successful.
  /// If not successful, it will throw an [AuthRequestError].
  Future<AuthToken> refresh(
      String? refreshToken, String? clientID, String? clientSecret,
      {List<AuthScope>? requestedScopes}) async {
    if (clientID == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    final client = await getClient(clientID);
    if (client == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (refreshToken == null) {
      throw AuthServerException(AuthRequestError.invalidRequest, client);
    }

    final t = await delegate.getToken(this, byRefreshToken: refreshToken);
    if (t == null || t.clientID != clientID) {
      throw AuthServerException(AuthRequestError.invalidGrant, client);
    }

    if (clientSecret == null) {
      throw AuthServerException(AuthRequestError.invalidClient, client);
    }

    if (client.hashedSecret != hashPassword(clientSecret, client.salt ?? "")) {
      throw AuthServerException(AuthRequestError.invalidClient, client);
    }

    var updatedScopes = t.scopes;
    if ((requestedScopes?.length ?? 0) != 0) {
      // If we do specify scope
      for (var incomingScope in requestedScopes!) {
        final hasExistingScopeOrSuperset = t.scopes?.any((existingScope) =>
                incomingScope.isSubsetOrEqualTo(existingScope)) ??
            false;

        if (!hasExistingScopeOrSuperset) {
          throw AuthServerException(AuthRequestError.invalidScope, client);
        }

        if (!client.allowsScope(incomingScope)) {
          throw AuthServerException(AuthRequestError.invalidScope, client);
        }
      }

      updatedScopes = requestedScopes;
    } else if (client.supportsScopes) {
      // Ensure we still have access to same scopes if we didn't specify any
      for (var incomingScope in t.scopes!) {
        if (!client.allowsScope(incomingScope)) {
          throw AuthServerException(AuthRequestError.invalidScope, client);
        }
      }
    }

    final diff = t.expirationDate!.difference(t.issueDate!);
    final now = DateTime.now().toUtc();
    final newToken = AuthToken()
      ..accessToken = randomStringOfLength(32)
      ..issueDate = now
      ..expirationDate = now.add(Duration(seconds: diff.inSeconds)).toUtc()
      ..refreshToken = t.refreshToken
      ..type = t.type
      ..scopes = updatedScopes
      ..resourceOwnerIdentifier = t.resourceOwnerIdentifier
      ..clientID = t.clientID;

    await delegate.updateToken(this, t.accessToken, newToken.accessToken,
        newToken.issueDate, newToken.expirationDate);

    return newToken;
  }

  /// Creates a one-time use authorization code for a given client ID and user credentials.
  ///
  /// This methods works with this instance's [delegate] to generate and store the authorization code
  /// if the credentials are correct. If they are not correct, it will throw the
  /// appropriate [AuthRequestError].
  Future<AuthCode> authenticateForCode(
      String? username, String? password, String? clientID,
      {int expirationInSeconds = 600, List<AuthScope>? requestedScopes}) async {
    if (clientID == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    final client = await getClient(clientID);
    if (client == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (username == null || password == null) {
      throw AuthServerException(AuthRequestError.invalidRequest, client);
    }

    if (client.redirectURI == null) {
      throw AuthServerException(AuthRequestError.unauthorizedClient, client);
    }

    final authenticatable = await delegate.getResourceOwner(this, username);
    if (authenticatable == null) {
      throw AuthServerException(AuthRequestError.accessDenied, client);
    }

    final dbSalt = authenticatable.salt;
    final dbPassword = authenticatable.hashedPassword;
    if (hashPassword(password, dbSalt!) != dbPassword) {
      throw AuthServerException(AuthRequestError.accessDenied, client);
    }

    final validScopes =
        _validatedScopes(client, authenticatable, requestedScopes);
    final authCode = _generateAuthCode(
        authenticatable.id, client, expirationInSeconds,
        scopes: validScopes);
    await delegate.addCode(this, authCode);
    return authCode;
  }

  /// Exchanges a valid authorization code for an [AuthToken].
  ///
  /// If the authorization code has not expired, has not been used, matches the client ID,
  /// and the client secret is correct, it will return a valid [AuthToken]. Otherwise,
  /// it will throw an appropriate [AuthRequestError].
  Future<AuthToken> exchange(
      String? authCodeString, String? clientID, String? clientSecret,
      {int expirationInSeconds = 3600}) async {
    if (clientID == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    final client = await getClient(clientID);
    if (client == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (authCodeString == null) {
      throw AuthServerException(AuthRequestError.invalidRequest, null);
    }

    if (clientSecret == null) {
      throw AuthServerException(AuthRequestError.invalidClient, client);
    }

    if (client.hashedSecret != hashPassword(clientSecret, client.salt!)) {
      throw AuthServerException(AuthRequestError.invalidClient, client);
    }

    final authCode = await delegate.getCode(this, authCodeString);
    if (authCode == null) {
      throw AuthServerException(AuthRequestError.invalidGrant, client);
    }

    // check if valid still
    if (authCode.isExpired) {
      await delegate.removeCode(this, authCode.code);
      throw AuthServerException(AuthRequestError.invalidGrant, client);
    }

    // check that client ids match
    if (authCode.clientID != client.id) {
      throw AuthServerException(AuthRequestError.invalidGrant, client);
    }

    // check to see if has already been used
    if (authCode.hasBeenExchanged!) {
      await delegate.removeToken(this, authCode);

      throw AuthServerException(AuthRequestError.invalidGrant, client);
    }
    final token = _generateToken(
        authCode.resourceOwnerIdentifier, client.id, expirationInSeconds,
        scopes: authCode.requestedScopes);
    await delegate.addToken(this, token, issuedFrom: authCode);

    return token;
  }

  //////
  // APIDocumentable overrides
  //////

  @override
  void documentComponents(APIDocumentContext context) {
    final basic = APISecurityScheme.http("basic")
      ..description =
          "This endpoint requires an OAuth2 Client ID and Secret as the Basic Authentication username and password. "
              "If the client ID does not have a secret (public client), the password is the empty string (retain the separating colon, e.g. 'com.aqueduct.app:').";
    context.securitySchemes.register("oauth2-client-authentication", basic);

    final oauth2 = APISecurityScheme.oauth2({
      "authorizationCode": documentedAuthorizationCodeFlow,
      "password": documentedPasswordFlow
    })
      ..description = "Standard OAuth 2.0";

    context.securitySchemes.register("oauth2", oauth2);

    context.defer(() {
      if (documentedAuthorizationCodeFlow.authorizationURL == null) {
        oauth2.flows?.remove("authorizationCode");
      }

      if (documentedAuthorizationCodeFlow.tokenURL == null) {
        oauth2.flows?.remove("authorizationCode");
      }

      if (documentedPasswordFlow.tokenURL == null) {
        oauth2.flows?.remove("password");
      }
    });
  }

  /////
  // AuthValidator overrides
  /////
  @override
  List<APISecurityRequirement> documentRequirementsForAuthorizer(
      APIDocumentContext context, Authorizer authorizer,
      {List<AuthScope>? scopes}) {
    if (authorizer.parser is AuthorizationBasicParser) {
      return [
        APISecurityRequirement({"oauth2-client-authentication": []})
      ];
    } else if (authorizer.parser is AuthorizationBearerParser) {
      return [
        APISecurityRequirement(
            {"oauth2": scopes?.map((s) => s.toString()).toList() ?? []})
      ];
    }

    return [];
  }

  @override
  FutureOr<Authorization> validate<T>(
      AuthorizationParser<T> parser, T authorizationData,
      {List<AuthScope>? requiredScope}) {
    if (parser is AuthorizationBasicParser) {
      final credentials = authorizationData as AuthBasicCredentials;
      return _validateClientCredentials(credentials);
    } else if (parser is AuthorizationBearerParser) {
      return verify(authorizationData as String, scopesRequired: requiredScope);
    }

    throw ArgumentError(
        "Invalid 'parser' for 'AuthServer.validate'. Use 'AuthorizationBasicParser' or 'AuthorizationBearerHeader'.");
  }

  Future<Authorization> _validateClientCredentials(
      AuthBasicCredentials credentials) async {
    final username = credentials.username ?? "";
    final password = credentials.password ?? "";

    final client = await getClient(username);

    if (client == null) {
      throw AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (client.hashedSecret == null) {
      if (password == "") {
        return Authorization(client.id, null, this, credentials: credentials);
      }

      throw AuthServerException(AuthRequestError.invalidClient, client);
    }

    if (client.hashedSecret != hashPassword(password, client.salt!)) {
      throw AuthServerException(AuthRequestError.invalidClient, client);
    }

    return Authorization(client.id, null, this, credentials: credentials);
  }

  List<AuthScope>? _validatedScopes(AuthClient client,
      ResourceOwner authenticatable, List<AuthScope>? requestedScopes) {
    List<AuthScope>? validScopes;
    if (client.supportsScopes) {
      if ((requestedScopes?.length ?? 0) == 0) {
        throw AuthServerException(AuthRequestError.invalidScope, client);
      }

      validScopes = requestedScopes!
          .where((incomingScope) => client.allowsScope(incomingScope))
          .toList();

      if (validScopes.isEmpty) {
        throw AuthServerException(AuthRequestError.invalidScope, client);
      }

      final validScopesForAuthenticatable =
          delegate.getAllowedScopes(authenticatable);
      if (!identical(validScopesForAuthenticatable, AuthScope.any)) {
        validScopes.retainWhere((clientAllowedScope) =>
            validScopesForAuthenticatable.any((userScope) =>
                clientAllowedScope.isSubsetOrEqualTo(userScope)));

        if (validScopes.isEmpty) {
          throw AuthServerException(AuthRequestError.invalidScope, client);
        }
      }
    }

    return validScopes;
  }

  AuthToken _generateToken(
      int? ownerID, String clientID, int expirationInSeconds,
      {bool allowRefresh = true, List<AuthScope>? scopes}) {
    final now = DateTime.now().toUtc();
    final token = AuthToken()
      ..accessToken = randomStringOfLength(32)
      ..issueDate = now
      ..expirationDate = now.add(Duration(seconds: expirationInSeconds))
      ..type = tokenTypeBearer
      ..resourceOwnerIdentifier = ownerID
      ..scopes = scopes
      ..clientID = clientID;

    if (allowRefresh) {
      token.refreshToken = randomStringOfLength(32);
    }

    return token;
  }

  AuthCode _generateAuthCode(
      int ownerID, AuthClient client, int expirationInSeconds,
      {List<AuthScope>? scopes}) {
    final now = DateTime.now().toUtc();
    return AuthCode()
      ..code = randomStringOfLength(32)
      ..clientID = client.id
      ..resourceOwnerIdentifier = ownerID
      ..issueDate = now
      ..requestedScopes = scopes
      ..expirationDate = now.add(Duration(seconds: expirationInSeconds));
  }
}
