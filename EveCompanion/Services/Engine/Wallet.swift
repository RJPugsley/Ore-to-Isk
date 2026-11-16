import Foundation

/// Originally `wallet.py`: balance and the last few days of ISK in / out,
/// grouped into readable categories. Needs esi-wallet.read_character_wallet.v1.
enum Wallet {
    /// ESI journal ref_type → label shown in the app. Anything else is "Other".
    static let categories: [String: String] = [
        "market_transaction": "Market trades",
        "market_escrow": "Buy order escrow",
        "transaction_tax": "Sales tax",
        "brokers_fee": "Broker fees",
        "industry_job_tax": "Industry job fees",
        "manufacturing": "Industry job fees",
        "reprocessing_tax": "Reprocessing tax",
        "bounty_prizes": "Bounties",
        "agent_mission_reward": "Missions",
        "agent_mission_time_bonus_reward": "Missions",
        "player_donation": "Transfers",
        "corporation_account_withdrawal": "Transfers",
        "contract_price": "Contracts",
        "contract_reward": "Contracts",
        "contract_collateral": "Contracts",
        "contract_brokers_fee": "Contracts",
        "insurance": "Insurance",
        "skill_purchase": "Skill books",
        "clone_activation": "Clones",
        "jump_clone_installation_fee": "Clones",
        "planetary_import_tax": "Planetary tax",
        "planetary_export_tax": "Planetary tax",
    ]

    static func summary(days: Int = 7) async throws -> JSONDict {
        let cid = try await EveAuth.shared.characterID()
        let balanceValue = try await ESI.get("characters/\(cid)/wallet/")
        let balance = (balanceValue as? NSNumber)?.doubleValue ?? 0
        let journal = asDicts(try await ESI.getAllPages("characters/\(cid)/wallet/journal/"))

        let now = Date()
        let since = now.addingTimeInterval(-Double(days) * 86400)
        var order: [String] = []
        var income = 0.0, spending = 0.0
        var catIncome: [String: Double] = [:], catSpending: [String: Double] = [:]
        var daily: [String: Double] = [:]
        for i in 0..<days { daily[ISODate.day(now.addingTimeInterval(-Double(i) * 86400))] = 0.0 }

        for entry in journal {
            guard let when = ISODate.parse(entry.string("date")), when >= since else { continue }
            let amount = entry.double("amount") ?? 0.0
            let label = categories[entry.string("ref_type") ?? ""] ?? "Other"
            if catIncome[label] == nil {
                order.append(label)
                catIncome[label] = 0
                catSpending[label] = 0
            }
            if amount >= 0 {
                income += amount
                catIncome[label]! += amount
            } else {
                spending += -amount
                catSpending[label]! += -amount
            }
            let day = ISODate.day(when)
            if daily[day] != nil { daily[day]! += amount }
        }

        let categoryRows: [JSONDict] = order
            .map { ["name": $0, "income": catIncome[$0] ?? 0, "spending": catSpending[$0] ?? 0] as JSONDict }
            .sorted { -(($0.double("income") ?? 0) + ($0.double("spending") ?? 0))
                    < -(($1.double("income") ?? 0) + ($1.double("spending") ?? 0)) }

        return [
            "balance": balanceValue,
            "balance_value": balance,
            "days": days,
            "income": income,
            "spending": spending,
            "net": income - spending,
            "categories": categoryRows,
            "daily": daily.keys.sorted().map { ["date": $0, "net": daily[$0] ?? 0] as JSONDict },
        ]
    }
}
