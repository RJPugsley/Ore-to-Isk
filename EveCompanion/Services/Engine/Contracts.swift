import Foundation

/// Public contracts: what blueprint copies sell for.
///
/// ESI can't search contracts by item, so a region is read in two steps:
///   1. every public contract in the region (a few pages, cached by ESI for 30 minutes)
///   2. the items of each item-exchange contract – one call each, but a contract's items
///      never change, so they're stored in history.sqlite and only new contracts are read.
/// The first scan of a region takes a minute or two; after that only the newcomers.
enum Contracts {
    /// {blueprint type id: [offer]} for contracts selling exactly one blueprint copy.
    /// offer = {contract_id, price, runs, me, te, price_per_run, location_id, expires, title}
    static func copyOffers(regionID: Int) async throws -> [Int: [JSONDict]] {
        try await cached("bpc_offers:\(regionID)", ttl: 1800) {
            try await scan(regionID)
        }
    }

    private static func scan(_ regionID: Int) async throws -> [Int: [JSONDict]] {
        let all = asDicts(try await ESI.getAllPages("contracts/public/\(regionID)/", auth: false))
        let sales = all.filter { $0.string("type") == "item_exchange" && ($0.double("price") ?? 0) > 0 }
        let ids = sales.compactMap { $0.int("contract_id") }

        // Read the items of contracts we haven't seen before.
        let store = HistoryStore.shared
        let known = await store.scannedContracts(ids)
        let newIDs = ids.filter { !known.contains($0) }
        let fetched = try await concurrentMap(newIDs, limit: 20) { id -> (Int, [JSONDict]?) in
            do {
                let items = asDicts(try await ESI.getAllPages("contracts/public/items/\(id)/", auth: false))
                return (id, items)
            } catch {
                // Gone or hidden (404/403): nothing to read – remember that so we don't ask again.
                if let status = httpStatus(of: error), [403, 404, 410].contains(status) { return (id, []) }
                return (id, nil)   // timeout etc. – try again on the next scan
            }
        }
        for (id, items) in fetched {
            if let items { await store.saveContractItems(id, items) }
        }
        await store.touchContracts(ids)

        // Keep contracts that sell exactly one blueprint copy and nothing else.
        let itemsByContract = await store.contractItems(ids)
        var offers: [Int: [JSONDict]] = [:]
        for contract in sales {
            guard let id = contract.int("contract_id"), let items = itemsByContract[id] else { continue }
            let included = items.filter { ($0.int("is_included") ?? 0) == 1 }
            guard included.count == 1, items.count == 1, let item = included.first,
                  (item.int("is_copy") ?? 0) == 1, let typeID = item.int("type_id") else { continue }
            let runs = item.int("runs") ?? 0
            let price = contract.double("price") ?? 0
            guard runs > 0, price > 0 else { continue }
            let perRun: Double = price / Double(runs)
            offers[typeID, default: []].append([
                "contract_id": id,
                "type_id": typeID,
                "price": price,
                "runs": runs,
                "me": item.int("me") ?? 0,
                "te": item.int("te") ?? 0,
                "price_per_run": perRun,
                "location_id": contract.int("start_location_id") as Any,
                "expires": contract.string("date_expired") as Any,
                "title": contract.string("title") as Any,
            ])
        }
        // Track what disappears between scans (probably sold).
        let allOffers: [JSONDict] = offers.values.flatMap { $0 }
        await store.trackCopyContracts(regionID: regionID, offers: allOffers, openIDs: Set(ids))
        return offers
    }

    /// Copies that probably sold in the region over the last `days` days (0 = all; see trackCopyContracts).
    static func copySales(regionID: Int, days: Int = HistoryRange.days) async -> (sales: [Int: JSONDict], since: Double?) {
        await HistoryStore.shared.copySales(regionID: regionID, days: days)
    }
}
