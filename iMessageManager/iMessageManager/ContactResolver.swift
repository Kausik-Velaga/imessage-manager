import Contacts
import Foundation

struct ContactResolver {
    nonisolated static let empty = ContactResolver(namesByEmail: [:], namesByPhoneKey: [:])

    private let namesByEmail: [String: String]
    private let namesByPhoneKey: [String: String]

    nonisolated static func load() async -> ContactResolver {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .notDetermined {
            let granted = await requestAccess(store)
            guard granted else {
                return .empty
            }
        } else if status != .authorized {
            return .empty
        }

        return await Task.detached {
            loadAuthorizedContacts(from: store)
        }.value
    }

    nonisolated func displayName(for handle: String) -> String? {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailKey = trimmedHandle.lowercased()

        if let name = namesByEmail[emailKey] {
            return name
        }

        let phoneDigits = Self.phoneDigits(trimmedHandle)
        guard !phoneDigits.isEmpty else {
            return nil
        }

        return Self.phoneLookupKeys(for: phoneDigits).compactMap { namesByPhoneKey[$0] }.first
    }

    nonisolated private static func requestAccess(_ store: CNContactStore) async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func loadAuthorizedContacts(from store: CNContactStore) -> ContactResolver {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var namesByEmail: [String: String] = [:]
        var namesByPhoneKey: [String: String] = [:]

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                guard let displayName = displayName(for: contact) else {
                    return
                }

                for emailAddress in contact.emailAddresses {
                    let key = String(emailAddress.value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    insert(displayName, for: key, into: &namesByEmail)
                }

                for phoneNumber in contact.phoneNumbers {
                    let digits = phoneDigits(phoneNumber.value.stringValue)
                    for key in phoneLookupKeys(for: digits) {
                        insert(displayName, for: key, into: &namesByPhoneKey)
                    }
                }
            }
        } catch {
            return .empty
        }

        return ContactResolver(namesByEmail: namesByEmail, namesByPhoneKey: namesByPhoneKey)
    }

    nonisolated private static func displayName(for contact: CNContact) -> String? {
        let fullName = [
            contact.givenName,
            contact.middleName,
            contact.familyName
        ]
        .compactMap(nonEmpty)
        .joined(separator: " ")

        if let displayName = nonEmpty(fullName) {
            return displayName
        }

        if let nickname = nonEmpty(contact.nickname) {
            return nickname
        }

        return nonEmpty(contact.organizationName)
    }

    nonisolated private static func phoneLookupKeys(for digits: String) -> [String] {
        guard !digits.isEmpty else {
            return []
        }

        var keys = [digits]

        if digits.count > 10 {
            keys.append(String(digits.suffix(10)))
        }

        if digits.count > 7 {
            keys.append(String(digits.suffix(7)))
        }

        return Array(Set(keys))
    }

    nonisolated private static func phoneDigits(_ value: String) -> String {
        String(value.filter(\.isNumber))
    }

    nonisolated private static func insert(_ value: String, for key: String, into dictionary: inout [String: String]) {
        guard !key.isEmpty else {
            return
        }

        if dictionary[key] == nil {
            dictionary[key] = value
        }
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }

        return trimmedValue
    }
}
