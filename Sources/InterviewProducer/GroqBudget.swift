import Foundation
/// Conservative client-side ceilings; user's Groq organization must actually be on Free.
actor ProducerGroqBudget {
    static let shared = ProducerGroqBudget()
    struct Reservation: Codable { var date: Date; var seconds: Double }
    private var nextRequest = Date.distantPast
    func reserve(seconds: Double, now: Date = Date()) async throws {
        guard ProducerDefaults.shared.bool(forKey:"producer.groqFreeConfirmed") else { throw ProducerError.message("Confirm that your Groq organization uses the Free plan before sending audio.") }
        let delay = nextRequest.timeIntervalSince(now)
        nextRequest = max(now,nextRequest).addingTimeInterval(3.2)
        if delay > 0 { try await Task.sleep(for:.seconds(delay)) }
        try Task.checkCancellation()
        let current = Date()
        let d = ProducerDefaults.shared
        var items = d.data(forKey:"producer.groqLedger").flatMap { try? JSONDecoder().decode([Reservation].self,from:$0) } ?? []
        items.removeAll { current.timeIntervalSince($0.date) > 86400 }
        let charge = max(10,seconds)
        guard items.filter({current.timeIntervalSince($0.date) < 3600}).reduce(0,{$0+$1.seconds})+charge <= 7000,
              items.reduce(0,{$0+$1.seconds})+charge <= 28000,
              items.count < 1900 else { throw ProducerError.message("Local Groq free allowance guard reached. Transcription paused; recording continues. No paid fallback.") }
        items.append(.init(date:current,seconds:charge))
        d.set(try JSONEncoder().encode(items),forKey:"producer.groqLedger")
    }
}
