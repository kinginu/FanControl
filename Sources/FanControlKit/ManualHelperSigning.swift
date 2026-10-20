#if os(macOS)
import Foundation
import Security
import FanControlCore
import FanControlXPC

/// Code-signing lookups for the manual-install (personal) mode
/// (`FanControlHelperConstants` + `ManualInstallMode.swift`, docs/kit.md).
enum ManualHelperSigning {
    /// Team identifier of the running app's own signature, or `nil` when it has none
    /// (ad-hoc / unsigned). Computed once.
    static let ownTeamIdentifier: String? = {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        guard let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }()

    /// cdhash (40 lower-case hex digits) of the helper installed at `path`.
    ///
    /// Trust anchor: the file must be owned by root and not group/other-writable, and so
    /// must its directory. Only root can then have placed or changed it, i.e. the user
    /// ran `sudo install.sh`, and root can subvert this app in any case. Pinning its
    /// cdhash therefore adds no trust beyond "what root installed", while still
    /// refusing a different process that registered the Mach name (which in the system
    /// domain also requires root) with another binary. The signature itself is
    /// validated (`SecStaticCodeCheckValidity`) so a tampered file is rejected rather
    /// than pinned.
    static func installedHelperCDHash(atPath path: String = FanControlHelperConstants.manualHelperPath) throws -> String {
        let fm = FileManager.default
        for item in [path, (path as NSString).deletingLastPathComponent] {
            guard let attrs = try? fm.attributesOfItem(atPath: item),
                  let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value,
                  let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
                throw FanControlError.helperConnectionFailed("Cannot read \(item) (manual helper installation). Run sudo \(FanControlHelperConstants.manualInstallScriptName).")
            }
            guard FanControlHelperConstants.isRootOwnedAndProtected(ownerUID: owner, permissions: mode) else {
                throw FanControlError.helperConnectionFailed(
                    "\(item) must be owned by root and not writable by group/others (owner uid \(owner), mode \(String(mode, radix: 8))); refusing to trust it.")
            }
        }
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw FanControlError.helperConnectionFailed("SecStaticCodeCreateWithPath(\(path)) failed: \(status)")
        }
        status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else {
            throw FanControlError.helperConnectionFailed("The helper at \(path) has an invalid code signature (\(status)).")
        }
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, [], &info)
        guard status == errSecSuccess, let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data else {
            throw FanControlError.helperConnectionFailed("Cannot read the cdhash of \(path) (\(status)).")
        }
        let hex = unique.map { String(format: "%02x", $0) }.joined()
        guard let hash = FanControlHelperConstants.normalizedCDHash(hex) else {
            throw FanControlError.helperConnectionFailed("Unexpected cdhash length for \(path): \(hex)")
        }
        return hash
    }
}
#endif
