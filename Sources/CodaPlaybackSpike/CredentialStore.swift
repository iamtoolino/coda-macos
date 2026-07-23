import Foundation
import Security

struct StoredLogin: Codable, Equatable, Sendable {
  let serverURL: String
  let username: String
  let password: String

  init(serverURL: String, username: String, password: String) {
    self.serverURL = serverURL
    self.username = username
    self.password = password
  }

  init(configuration: NavidromeConfiguration) {
    serverURL = configuration.serverURL.absoluteString
    username = configuration.username
    password = configuration.password
  }

  var configuration: NavidromeConfiguration {
    get throws {
      try NavidromeConfiguration(
        server: serverURL,
        username: username,
        password: password
      )
    }
  }
}

enum CredentialStore {
  private static let service = "io.github.iamtoolino.coda.macos.navidrome"
  private static let account = "default"
  private static let accessPolicyMigrationKey =
    "CredentialStore.stableSignedApplicationAccess.v2"
  private static let legacyAccessPolicyMigrationKey =
    "CredentialStore.stableSignedApplicationAccess.v1"

  static func load() throws -> StoredLogin? {
    var query = baseQuery
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw CredentialStoreError.keychain(status)
    }
    guard let data = result as? Data else {
      throw CredentialStoreError.invalidStoredLogin
    }

    let login: StoredLogin
    do {
      login = try JSONDecoder().decode(StoredLogin.self, from: data)
    } catch {
      throw CredentialStoreError.invalidStoredLogin
    }
    try migrateAccessPolicyIfNeeded()
    return login
  }

  static func save(_ login: StoredLogin) throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(login)
    } catch {
      throw CredentialStoreError.encoding(error.localizedDescription)
    }

    let access = try applicationAccess()
    let updatedValues: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccess as String: access,
    ]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updatedValues as CFDictionary)
    if updateStatus == errSecSuccess {
      markAccessPolicyCurrent()
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw CredentialStoreError.keychain(updateStatus)
    }

    var item = baseQuery
    item.merge(updatedValues) { _, new in new }
    item[kSecAttrLabel as String] = "Coda Navidrome Login"
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw CredentialStoreError.keychain(addStatus)
    }
    markAccessPolicyCurrent()
  }

  static func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.keychain(status)
    }
    UserDefaults.standard.removeObject(forKey: accessPolicyMigrationKey)
  }

  static func loadForDevelopmentTest() throws -> NavidromeConfiguration {
    let environment = ProcessInfo.processInfo.environment
    if let server = environment["CODA_SERVER_URL"],
      let username = environment["CODA_USERNAME"],
      let password = environment["CODA_PASSWORD"]
    {
      return try NavidromeConfiguration(
        server: server,
        username: username,
        password: password
      )
    }

    if let stored = try load() {
      return try stored.configuration
    }
    throw CredentialStoreError.noStoredLogin
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func migrateAccessPolicyIfNeeded() throws {
    guard !UserDefaults.standard.bool(forKey: accessPolicyMigrationKey) else { return }
    let access = try applicationAccess()
    let status = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecAttrAccess as String: access] as CFDictionary
    )
    guard status == errSecSuccess else {
      throw CredentialStoreError.keychain(status)
    }
    markAccessPolicyCurrent()
  }

  private static func applicationAccess() throws -> SecAccess {
    var trustedApplication: SecTrustedApplication?
    let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
    guard trustedStatus == errSecSuccess, let trustedApplication else {
      throw CredentialStoreError.keychain(trustedStatus)
    }

    var access: SecAccess?
    let accessStatus = SecAccessCreate(
      "Coda Navidrome Login" as CFString,
      [trustedApplication] as CFArray,
      &access
    )
    guard accessStatus == errSecSuccess, let access else {
      throw CredentialStoreError.keychain(accessStatus)
    }
    return access
  }

  private static func markAccessPolicyCurrent() {
    UserDefaults.standard.set(true, forKey: accessPolicyMigrationKey)
    UserDefaults.standard.removeObject(forKey: legacyAccessPolicyMigrationKey)
  }
}

enum CredentialStoreError: LocalizedError {
  case keychain(OSStatus)
  case invalidStoredLogin
  case encoding(String)
  case noStoredLogin
  case notConnected

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
      return "Coda could not access the login Keychain: \(detail)."
    case .invalidStoredLogin:
      return "The saved Coda login in Keychain is invalid. Sign in again."
    case .encoding(let message):
      return "Coda could not prepare the login for Keychain: \(message)"
    case .noStoredLogin:
      return "No Coda login is stored. Sign in first or provide CODA_SERVER_URL, CODA_USERNAME, and CODA_PASSWORD."
    case .notConnected:
      return "Sign in to Navidrome first."
    }
  }
}
