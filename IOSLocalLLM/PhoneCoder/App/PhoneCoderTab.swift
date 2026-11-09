enum PhoneCoderTab: String, CaseIterable, Identifiable {
    case chat
    case models
    case server
    case images
    case settings

    var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .chat: return "Chat"
        case .models: return "Models"
        case .server: return "Server"
        case .images: return "Images"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .models: return "shippingbox"
        case .server: return "server.rack"
        case .images: return "photo"
        case .settings: return "gearshape"
        }
    }
}
