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
    "CredentialStore.stableSignedApplicationAccess.v3"
  private static let legacyAccessPolicyMigrationKeys = [
    "CredentialStore.stableSignedApplicationAccess.v1",
    "CredentialStore.stableSignedApplicationAccess.v2",
  ]

  static func load() throws -> StoredLogin? {
    #if DEBUG
      if let login = try loadDevelopmentLogin() {
        return login
      }
      let login = try loadFromKeychain()
      if let login {
        try saveDevelopmentLogin(login)
      }
      return login
    #else
      return try loadFromKeychain()
    #endif
  }

  static func save(_ login: StoredLogin) throws {
    #if DEBUG
      try saveDevelopmentLogin(login)
    #else
      try saveToKeychain(login)
    #endif
  }

  static func delete() throws {
    #if DEBUG
      try deleteDevelopmentLogin()
      try deleteFromKeychain()
    #else
      try deleteFromKeychain()
    #endif
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

  private static func loadFromKeychain() throws -> StoredLogin? {
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
    #if !DEBUG
      try migrateAccessPolicyIfNeeded()
    #endif
    return login
  }

  private static func saveToKeychain(_ login: StoredLogin) throws {
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

  private static func deleteFromKeychain() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.keychain(status)
    }
    UserDefaults.standard.removeObject(forKey: accessPolicyMigrationKey)
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
    for key in legacyAccessPolicyMigrationKeys {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  #if DEBUG
    private static var developmentLoginURL: URL {
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0]
      .appendingPathComponent("Coda", isDirectory: true)
      .appendingPathComponent("DevelopmentLogin.json", isDirectory: false)
    }

    private static func loadDevelopmentLogin() throws -> StoredLogin? {
      let url = developmentLoginURL
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StoredLogin.self, from: data)
      } catch {
        throw CredentialStoreError.developmentStorage(error.localizedDescription)
      }
    }

    private static func saveDevelopmentLogin(_ login: StoredLogin) throws {
      let url = developmentLoginURL
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let data = try JSONEncoder().encode(login)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o600)],
          ofItemAtPath: url.path
        )
      } catch {
        throw CredentialStoreError.developmentStorage(error.localizedDescription)
      }
    }

    private static func deleteDevelopmentLogin() throws {
      let url = developmentLoginURL
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        throw CredentialStoreError.developmentStorage(error.localizedDescription)
      }
    }
  #endif
}

enum CredentialStoreError: LocalizedError {
  case keychain(OSStatus)
  case invalidStoredLogin
  case encoding(String)
  case developmentStorage(String)
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
    case .developmentStorage(let message):
      return "Coda could not access its local development login: \(message)"
    case .noStoredLogin:
      return "No Coda login is stored. Sign in first or provide CODA_SERVER_URL, CODA_USERNAME, and CODA_PASSWORD."
    case .notConnected:
      return "Sign in to Navidrome first."
    }
  }
}
