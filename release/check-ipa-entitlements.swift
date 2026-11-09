import Foundation
import Security

func fail(_ message: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: check-ipa-entitlements.swift EXECUTABLE", 2)
}
var code: SecStaticCode?
var information: CFDictionary?
let loadStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                          [], &code)
guard loadStatus == errSecSuccess, let code else {
    fail("Cannot load signed executable: \(SecCopyErrorMessageString(loadStatus, nil) as String? ?? "OSStatus \(loadStatus)")", 2)
}
let readStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                             &information)
guard readStatus == errSecSuccess, let information = information as? [String: Any] else {
    fail("Cannot read signing information: \(SecCopyErrorMessageString(readStatus, nil) as String? ?? "OSStatus \(readStatus)")", 2)
}
guard let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      let value = entitlements["com.apple.developer.kernel.increased-memory-limit"] as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else {
    // Distinct from Swift/compiler failures: only this status means rebuild the IPA.
    fail("Increased Memory Limit must be present and Boolean true", 3)
}
