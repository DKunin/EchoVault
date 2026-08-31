import Foundation

struct UserFacingAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
