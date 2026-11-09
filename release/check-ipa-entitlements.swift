import Foundation
import Security

var code: SecStaticCode?
var information: CFDictionary?
guard CommandLine.arguments.count == 2,
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                 [], &code) == errSecSuccess,
      let code,
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                    &information) == errSecSuccess,
      let information = information as? [String: Any],
      let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      let value = entitlements["com.apple.developer.kernel.increased-memory-limit"] as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else {
    exit(1)
}
