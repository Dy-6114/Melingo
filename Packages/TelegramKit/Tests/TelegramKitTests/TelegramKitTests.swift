import Testing
@testable import TelegramKit

@Test func normalizeUsernameStripsAtAndLinks() {
    #expect(ChannelExporter.normalizeUsername("@durov") == "durov")
    #expect(ChannelExporter.normalizeUsername("https://t.me/durov") == "durov")
    #expect(ChannelExporter.normalizeUsername("t.me/durov/123") == "durov")
}
