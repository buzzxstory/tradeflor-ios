import SwiftUI
import UIKit

// MARK: polls (styles/48-polls.css, groups/PollCard.tsx)

struct PollCard: View {
    let message: Message
    let me: String
    let canVote: Bool
    let onVote: ([Int]) -> Void

    private var def: (q: String, o: [String], multiple: Bool)? {
        guard let s = message.signal, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let opts = o["o"] as? [String] else { return nil }
        return ((o["q"] as? String) ?? "", opts, (o["multiple"] as? Bool) ?? false)
    }
    private var votes: [String: [String]] {
        guard let r = message.reactions, let d = r.data(using: .utf8),
              let m = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [:] }
        return m
    }

    var body: some View {
        if let p = def {
            let v = votes // decoded once per redraw (it was once per option, twice)
            let counts = p.o.indices.map { (v[String($0)] ?? []).count }
            let mine = p.o.indices.filter { (v[String($0)] ?? []).contains(me) }
            let total = counts.reduce(0, +)
            let voters = Set(v.values.flatMap { $0 }).count
            let showResults = !mine.isEmpty || !canVote
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("poll.chip", systemImage: "chart.bar").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent.opacity(0.12), in: Capsule())
                    Spacer()
                    Text(LocalizedStringKey(p.multiple ? "poll.multiple" : "poll.single")).font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                Text(p.q).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(p.o.enumerated()), id: \.offset) { i, option in
                    Button {
                        guard canVote else { return }
                        var next: [Int]
                        if p.multiple { next = mine.contains(i) ? mine.filter { $0 != i } : mine + [i] } else { next = mine.contains(i) ? [] : [i] }
                        onVote(next)
                    } label: {
                        ZStack(alignment: .leading) {
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(showResults ? 0.22 : 0))
                                    .frame(width: showResults && total > 0 ? g.size.width * CGFloat(counts[i]) / CGFloat(total) : 0)
                            }
                            HStack(spacing: 8) {
                                Text(String(Array("ABCDEFGHIJ")[min(i, 9)])).font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(mine.contains(i) ? Theme.onAccent : Theme.accent)
                                    .frame(width: 22, height: 22).background(mine.contains(i) ? Theme.accent : Theme.accent.opacity(0.12), in: Circle())
                                Text(option).font(.system(size: 14)).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                                Spacer()
                                if showResults && total > 0 {
                                    Text("\(Int((Double(counts[i]) / Double(total) * 100).rounded()))%").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(mine.contains(i) ? Theme.borderActive : Theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Text(voters == 1 ? NSLocalizedString("poll.voted.one", comment: "") : String(format: NSLocalizedString("poll.voted", comment: ""), voters))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                Text(LocalizedStringKey(!canVote ? "poll.hint.off" : (mine.isEmpty ? (p.multiple ? "poll.hint.multi" : "poll.hint.tap") : "poll.hint.undo")))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .padding(12)
            .frame(maxWidth: 300)
            .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderStrong, lineWidth: 1))
        }
    }
}

/// New poll (groups/PollComposer.tsx): a question, 2 to 10 options, and whether several may be chosen, in the panel it shares with
/// the trading-signal form (styles/81-composer-sheets.css, "cps"). One tap sends it once: a second tap while it goes is ignored.
struct PollComposer: View {
    let onSend: (String, [String], Bool) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multiple = false
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: PollField?

    private enum PollField: Hashable { case question, option(Int) }
    private static let maxOptions = 10

    private var filled: [String] { options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    /// What still stops the poll from being sent (the footer says it), or nil when it is ready.
    private var problem: String? {
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return NSLocalizedString("poll.err.q", comment: "") }
        if filled.count < 2 { return NSLocalizedString("poll.err.two", comment: "") }
        if Set(filled.map { $0.lowercased() }).count != filled.count { return NSLocalizedString("poll.err.dup", comment: "") }
        return nil
    }

    var body: some View {
        ComposerPanel(
            icon: CPSIcon.poll,
            title: NSLocalizedString("poll.new", comment: ""),
            subtitle: pc2("pc2.poll.sub", "Ask the group · 2 to 10 options"),
            hint: problem ?? pc2("pc2.poll.ready", "Ready to send"),
            hintOK: problem == nil,
            busy: busy,
            primaryTitle: busy ? NSLocalizedString("ct.sending", comment: "") : pc2("pc2.poll.send", "Send poll"),
            primaryEnabled: problem == nil && !busy,
            focusID: focus.map { AnyHashable($0) },
            onClose: { dismiss() },
            onPrimary: { post() }
        ) {
            VStack(alignment: .leading, spacing: 7) {
                cpsLabel(NSLocalizedString("poll.question", comment: ""), count: "\(question.count)/200")
                CPSField(placeholder: NSLocalizedString("poll.question.ph", comment: ""),
                         text: Binding(get: { question }, set: { question = String($0.prefix(200)) }),
                         focused: focus == .question)
                    .focused($focus, equals: .question)
                    .submitLabel(.next)
                    .onSubmit { focus = .option(0) }
            }
            .id(AnyHashable(PollField.question))

            cpsLabel(NSLocalizedString("poll.options", comment: ""), count: "\(filled.count)/\(Self.maxOptions)")
            VStack(spacing: 10) {
                ForEach(options.indices, id: \.self) { i in
                    optionRow(i).id(AnyHashable(PollField.option(i)))
                }
                if options.count < Self.maxOptions {
                    Button {
                        options.append("")
                        let added = options.count - 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .option(added) }
                    } label: {
                        HStack(spacing: 8) {
                            cpsIcon(CPSIcon.plus, size: 15, width: 2.2, color: Theme.gold)
                            Text(NSLocalizedString("poll.add", comment: "")).font(.system(size: 14.5, weight: .semibold))
                        }
                        .foregroundStyle(Theme.gold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .contentShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.gold.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }

            multipleSwitch

            if let error { Text(error).font(.system(size: 13)).foregroundStyle(CPS.error).fixedSize(horizontal: false, vertical: true) }
        }
        .interactiveDismissDisabled(busy)
        .tfColorScheme()
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if focus == nil { focus = .question } } }
    }

    private func optionRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            Text(String(Array("ABCDEFGHIJ")[min(i, 9)]))
                .font(.system(size: 13.5, weight: .heavy)).foregroundStyle(Theme.gold)
                .frame(width: 34, height: 34)
                .background(Theme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gold.opacity(0.35), lineWidth: 1))
                .accessibilityHidden(true)
            CPSField(placeholder: String(format: NSLocalizedString("poll.option.n", comment: ""), i + 1),
                     // a bound index that never reads past the end while a row is being removed
                     text: Binding(get: { i < options.count ? options[i] : "" },
                                   set: { if i < options.count { options[i] = String($0.prefix(100)) } }),
                     focused: focus == .option(i))
                .focused($focus, equals: .option(i))
                .submitLabel(i == options.count - 1 ? .done : .next)
                .onSubmit { focus = i < options.count - 1 ? PollField.option(i + 1) : nil }
            if options.count > 2 {
                Button {
                    focus = nil
                    if i < options.count { options.remove(at: i) }
                } label: {
                    cpsIcon(CPSIcon.close, size: 13, width: 2.2, color: Theme.faint)
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(CPS.fieldBorder, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(format: pc2("pc2.poll.remove", "Remove option %d"), i + 1)))
            }
        }
    }

    /// "Allow several answers": the web's switch (track on the leading side, the two lines next to it).
    private var multipleSwitch: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { multiple.toggle() }
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: multiple ? .trailing : .leading) {
                    Capsule().fill(multiple ? AnyShapeStyle(LinearGradient(colors: [Theme.hex(0x10D8DE), Theme.hex(0x03909B)],
                                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                                            : AnyShapeStyle(Theme.hex(0x1C3A45)))
                    Circle().fill(multiple ? Color.white : Theme.hex(0xCFE7EE)).frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        .padding(3)
                }
                .frame(width: 44, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(NSLocalizedString("poll.allow.multi", comment: "")).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(multiple ? pc2("pc2.poll.multi.on", "People can pick more than one option") : pc2("pc2.poll.multi.off", "People pick one option"))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(CPS.fieldBG, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(CPS.fieldBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(multiple ? .isSelected : [])
    }

    private func post() {
        guard !busy, problem == nil else { return } // a second tap while it goes is ignored
        busy = true
        error = nil
        focus = nil
        Task { await send() }
    }

    private func send() async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = await onSend(q, filled, multiple) {
            error = e
            busy = false
        } else {
            dismiss()
        }
    }
}

// MARK: trading signals (groups/SignalCard.tsx, SignalComposer.tsx)

struct SignalInfo {
    let symbol, direction, entry, stopLoss, takeProfit: String
    let status: String?

    init?(_ m: Message) {
        guard m.kind == "signal", let s = m.signal, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func v(_ k: String) -> String { (o[k] as? String) ?? (o[k].map { "\($0)" } ?? "") }
        symbol = v("symbol"); direction = v("direction"); entry = v("entry"); stopLoss = v("stop_loss"); takeProfit = v("take_profit1")
        status = o["status"] as? String
    }

    var isBuy: Bool { direction.lowercased() == "buy" }
    var riskReward: String? {
        guard let e = Double(entry), let sl = Double(stopLoss), let tp = Double(takeProfit), e != sl else { return nil }
        let r = abs(tp - e) / abs(e - sl)
        return String(format: "1:%.2f", r)
    }
}

struct SignalCard: View {
    let info: SignalInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(info.symbol).font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.text)
                Text(info.isBuy ? "BUY" : "SELL").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(info.isBuy ? Theme.buy : Theme.danger, in: Capsule())
                Spacer()
                if let s = info.status, !s.isEmpty, s != "pending" {
                    Text(Self.statusLabel(s)).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.gold)
                        .padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().stroke(Theme.gold.opacity(0.6), lineWidth: 1))
                }
            }
            HStack(spacing: 8) {
                cell("signal.entry", info.entry, Theme.text)
                cell("signal.sl", info.stopLoss, Theme.danger)
                cell("signal.tp", info.takeProfit, Theme.buy)
            }
            if let rr = info.riskReward {
                Text(String(format: NSLocalizedString("signal.rr", comment: ""), rr)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.gold)
            }
        }
        .padding(12)
        .frame(maxWidth: 300)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.gold.opacity(0.45), lineWidth: 1))
        .environment(\.layoutDirection, .leftToRight)
    }

    private func cell(_ key: LocalizedStringKey, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.system(size: 10)).foregroundStyle(Theme.faint)
            Text(v).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
    }

    static func statusLabel(_ s: String) -> String {
        switch s {
        case "active": return "ACTIVE"
        case "tp_hit", "target_hit": return "TARGET HIT"
        case "sl_hit", "stop_hit": return "STOP LOSS HIT"
        case "closed": return "CLOSED"
        case "cancelled", "canceled": return "CANCELLED"
        default: return s.uppercased()
        }
    }
}

/// New trading signal (groups/SignalComposer.tsx), in the panel it shares with the poll form (styles/81-composer-sheets.css, "cps").
/// Green and red appear only where they mean something: Buy / Sell and the stop-loss / take-profit labels. A signal whose prices
/// make no sense for its direction cannot be posted; the risk/reward shows as soon as the numbers are right. One tap posts it once.
struct SignalComposer: View {
    let onSend: (String, String, String, String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var symbol = ""
    @State private var buy = true
    @State private var entry = ""
    @State private var sl = ""
    @State private var tp = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: SignalField?

    private enum SignalField: Hashable { case symbol, entry, sl, tp }

    private static func num(_ v: String) -> Double? {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard let n = Double(t), n.isFinite, n > 0 else { return nil }
        return n
    }
    /// Which price is on the wrong side of the entry for the direction (only once all three read as numbers).
    private var wrong: (sl: Bool, tp: Bool) {
        guard let e = Self.num(entry), let s = Self.num(sl), let t = Self.num(tp) else { return (false, false) }
        let slBad = buy ? s >= e : s <= e
        let tpBad = !slBad && (buy ? t <= e : t >= e)
        return (slBad, tpBad)
    }
    private var hasProblem: Bool { wrong.sl || wrong.tp }
    private var ready: Bool {
        let all = [symbol, entry, sl, tp].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return all && !hasProblem
    }
    private var riskReward: String? {
        guard !hasProblem, let e = Self.num(entry), let s = Self.num(sl), let t = Self.num(tp), e != s else { return nil }
        return String(format: "1:%.1f", abs(t - e) / abs(e - s))
    }
    private var directionRule: String { NSLocalizedString(buy ? "signal.hint.buy" : "signal.hint.sell", comment: "") }

    var body: some View {
        let phone = sizeClass != .regular
        ComposerPanel(
            icon: CPSIcon.trend,
            title: NSLocalizedString("notify.signal", comment: ""),
            subtitle: pc2("pc2.signal.sub", "Entry, stop loss and take profit"),
            hint: ready ? pc2("pc2.signal.ready", "Ready to post") : pc2("pc2.signal.fill", "Fill in all prices"),
            hintOK: ready,
            busy: busy,
            primaryTitle: busy ? pc2("pc2.signal.posting", "Posting…") : pc2("pc2.signal.post", "Post signal"),
            primaryEnabled: ready && !busy,
            focusID: focus.map { AnyHashable($0) },
            onClose: { dismiss() },
            onPrimary: { post() }
        ) {
            // symbol + direction on one row
            CPSRow(ratios: phone ? [1, 1.25] : [1, 1.35], spacing: phone ? 10 : 14) {
                VStack(alignment: .leading, spacing: 7) {
                    cpsLabel(pc2("pc2.signal.symbol", "Symbol"))
                    CPSField(placeholder: "XAUUSD",
                             text: Binding(get: { symbol }, set: { symbol = String($0.uppercased().prefix(16)) }),
                             focused: focus == .symbol, weight: .bold, tracking: 0.64)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .symbol)
                        .submitLabel(.next)
                        .onSubmit { focus = SignalField.entry }
                }
                .id(AnyHashable(SignalField.symbol))
                VStack(alignment: .leading, spacing: 7) {
                    cpsLabel(NSLocalizedString("signal.direction", comment: ""))
                    directionPicker
                }
            }
            // the three prices on the next
            CPSRow(ratios: [1, 1, 1], spacing: phone ? 8 : 14) {
                priceField(.entry, NSLocalizedString("signal.entry", comment: ""), "0.00", $entry, labelColor: Theme.faint, tint: Theme.accent, isWrong: false)
                priceField(.sl, NSLocalizedString("signal.sl.long", comment: ""),
                           buy ? pc2("pc2.signal.below", "Below entry") : pc2("pc2.signal.above", "Above entry"),
                           $sl, labelColor: Theme.danger, tint: Theme.danger, isWrong: wrong.sl)
                priceField(.tp, NSLocalizedString("signal.tp.long", comment: ""),
                           buy ? pc2("pc2.signal.above", "Above entry") : pc2("pc2.signal.below", "Below entry"),
                           $tp, labelColor: Theme.buy, tint: Theme.buy, isWrong: wrong.tp)
            }
            // what to correct, the risk/reward, or the rule for the direction
            Group {
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(CPS.error)
                } else if hasProblem {
                    Text(directionRule).font(.system(size: 13)).foregroundStyle(CPS.error)
                } else if let rr = riskReward {
                    riskRewardChip(rr)
                } else {
                    Text(directionRule).font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
            }
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 20, alignment: .leading)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .interactiveDismissDisabled(busy)
        .tfColorScheme()
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if focus == nil { focus = .entry } } }
        .onChange(of: buy) { _ in error = nil }
    }

    private func priceField(_ field: SignalField, _ label: String, _ placeholder: String, _ text: Binding<String>,
                            labelColor: Color, tint: Color, isWrong: Bool) -> some View {
        let phone = sizeClass != .regular
        return VStack(alignment: .leading, spacing: 7) {
            cpsLabel(label, color: labelColor)
            CPSField(placeholder: placeholder, text: text, focused: focus == field, tint: tint, wrong: isWrong,
                     horizontalPadding: phone ? 10 : 14, weight: .semibold, digits: true, placeholderSize: phone ? 12.5 : 14.5)
                .keyboardType(.decimalPad)
                .focused($focus, equals: field)
        }
        .id(AnyHashable(field))
    }

    private var directionPicker: some View {
        HStack(spacing: 4) {
            directionButton(true)
            directionButton(false)
        }
        .padding(4)
        .frame(height: 48)
        .background(CPS.fieldBG, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(CPS.fieldBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("signal.direction"))
    }

    private func directionButton(_ isBuy: Bool) -> some View {
        let on = buy == isBuy
        let fill = isBuy ? Theme.buy : Theme.danger
        let fg = on ? (isBuy ? Theme.hex(0x04261A) : Color.white) : Theme.faint
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { buy = isBuy }
        } label: {
            HStack(spacing: 6) {
                cpsIcon(isBuy ? CPSIcon.up : CPSIcon.down, size: 15, width: 2.6, color: fg)
                Text(isBuy ? pc2("pc2.signal.buy", "Buy") : pc2("pc2.signal.sell", "Sell"))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(fg).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? fill : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: on ? fill.opacity(0.35) : .clear, radius: 6, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "Risk / Reward 1:2.0" with the ratio bold in gold (signal.rr carries the ratio as %@).
    private func riskRewardChip(_ rr: String) -> some View {
        let parts = NSLocalizedString("signal.rr", comment: "").components(separatedBy: "%@")
        let head = parts.first ?? ""
        let tail = parts.count > 1 ? parts[1] : ""
        return (Text(head) + Text(rr).bold().monospacedDigit().foregroundColor(Theme.gold) + Text(tail))
            .font(.system(size: 13)).foregroundColor(Theme.muted)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(Theme.gold.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(Theme.gold.opacity(0.3), lineWidth: 1))
    }

    private func post() {
        guard ready, !busy else { return } // a second tap while it goes is ignored
        busy = true
        error = nil
        focus = nil
        Task { await send() }
    }

    private func send() async {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let e = await onSend(t(symbol).uppercased(), buy ? "buy" : "sell", t(entry), t(sl), t(tp)) {
            error = e
            busy = false
        } else {
            dismiss()
        }
    }
}

// MARK: the composer panel shared by New poll and Trading signal (styles/81-composer-sheets.css, "cps")

/// Strings added with this panel; the English is the fallback until the key is in Localizable.strings.
private func pc2(_ key: String, _ en: String) -> String { NSLocalizedString(key, value: en, comment: "") }

private enum CPS {
    static let edge = Theme.dyn(0xEFBE33, 0xC89614, 0.38, 0.40)       // the panel's gold edge
    static let rule = Theme.dyn(0xEFBE33, 0xC89614, 0.14, 0.20)       // the line above the footer
    static let title = Theme.dyn(0xEFBE33, 0xA87C06)
    static let fieldBG = Theme.dyn(0x0D252F, 0xF3F7F9)                 // --bg-input
    static let fieldBorder = Theme.dyn(0x288CAF, 0x145A78, 0.22, 0.22) // --border-c
    static let placeholder = Theme.hex(0xA9B9C5, 0.55)
    static let error = Theme.hex(0xFF9A9F)
    static let shadow = Theme.dyn(0x000000, 0x14324B, 0.38, 0.16)
}

/// The web's stroked icons, drawn from their 24-unit SVG paths.
private enum CPSIcon {
    static let poll: [[CGPoint]] = [[p(5, 20), p(5, 11)], [p(12, 20), p(12, 4)], [p(19, 20), p(19, 14)]]
    static let trend: [[CGPoint]] = [[p(3, 17), p(8, 12), p(12, 16), p(20, 7)], [p(15, 7), p(20, 7), p(20, 12)]]
    static let close: [[CGPoint]] = [[p(6, 6), p(18, 18)], [p(18, 6), p(6, 18)]]
    static let plus: [[CGPoint]] = [[p(12, 5), p(12, 19)], [p(5, 12), p(19, 12)]]
    static let up: [[CGPoint]] = [[p(12, 19), p(12, 5)], [p(6, 11), p(12, 5), p(18, 11)]]
    static let down: [[CGPoint]] = [[p(12, 5), p(12, 19)], [p(6, 13), p(12, 19), p(18, 13)]]
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
}

private struct CPSStroke: Shape {
    let lines: [[CGPoint]]
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / 24
        func at(_ q: CGPoint) -> CGPoint { CGPoint(x: r.minX + q.x * k, y: r.minY + q.y * k) }
        var path = Path()
        for line in lines {
            guard let first = line.first else { continue }
            path.move(to: at(first))
            for q in line.dropFirst() { path.addLine(to: at(q)) }
        }
        return path
    }
}

/// An icon `size` points square, its stroke `width` in the SVG's 24-unit space (as the CSS sets it).
private func cpsIcon(_ lines: [[CGPoint]], size: CGFloat, width: CGFloat, color: Color) -> some View {
    CPSStroke(lines: lines)
        .stroke(color, style: StrokeStyle(lineWidth: width * size / 24, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
}

/// A field's small uppercase label, with an optional count at the far end ("3/10").
private func cpsLabel(_ title: String, count: String? = nil, color: Color = Theme.faint) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(title).font(.system(size: 11.5, weight: .bold)).tracking(0.92).textCase(.uppercase).foregroundStyle(color)
        Spacer(minLength: 0)
        if let count {
            Text(count).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.faint)
        }
    }
    .lineLimit(1)
}

/// Every text field of both forms: 48 points tall, rounded 13, the accent ring while it is being typed in.
private struct CPSField: View {
    let placeholder: String
    @Binding var text: String
    var focused: Bool
    var tint: Color = Theme.accent
    var wrong = false
    var horizontalPadding: CGFloat = 14
    var weight: Font.Weight = .medium
    var tracking: CGFloat = 0
    var digits = false
    var placeholderSize: CGFloat = 14.5

    var body: some View {
        let ring: Color = wrong ? Theme.danger : (focused ? tint : CPS.fieldBorder)
        let glow: Color = wrong ? Theme.danger.opacity(0.2) : (focused ? tint.opacity(0.15) : .clear)
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder).font(.system(size: placeholderSize)).foregroundStyle(CPS.placeholder).lineLimit(1)
                    .accessibilityHidden(true)
            }
            TextField("", text: $text)
                .font(digits ? .system(size: 16, weight: weight).monospacedDigit() : .system(size: 16, weight: weight))
                .tracking(tracking)
                .foregroundStyle(Theme.text)
                .tint(Theme.accent)
                .accessibilityLabel(Text(placeholder))
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: 48)
        .background(CPS.fieldBG, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(ring, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(glow, lineWidth: 3).padding(-3))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Columns in fixed proportions (the CSS grid's `minmax(0, 1fr) minmax(0, 1.35fr)`), their bottoms lined up.
private struct CPSRow: Layout {
    var ratios: [CGFloat]
    var spacing: CGFloat

    private func widths(_ total: CGFloat, _ n: Int) -> [CGFloat] {
        let r = (0..<n).map { $0 < ratios.count ? ratios[$0] : 1 }
        let sum = max(r.reduce(0, +), 0.001)
        let room = max(total - spacing * CGFloat(max(n - 1, 0)), 0)
        return r.map { room * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 360
        let w = widths(total, subviews.count)
        var h: CGFloat = 0
        for (i, s) in subviews.enumerated() { h = max(h, s.sizeThatFits(ProposedViewSize(width: w[i], height: nil)).height) }
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width, subviews.count)
        var x = bounds.minX
        for (i, s) in subviews.enumerated() {
            let h = s.sizeThatFits(ProposedViewSize(width: w[i], height: nil)).height
            s.place(at: CGPoint(x: x, y: bounds.maxY), anchor: .bottomLeading, proposal: ProposedViewSize(width: w[i], height: h))
            x += w[i] + spacing
        }
    }
}

private struct CPSBodyHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CPSPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// The panel: gold edge and gold top line, gold icon + title, a body that scrolls inside itself when it is taller than the room
/// (a 10-option poll), and a footer with a short state, Cancel and the main action. Up to 600 points wide and centred; on a phone
/// the full width (8 points each side) at the bottom of the sheet, so it sits right above the keyboard while typing.
private struct ComposerPanel<Content: View>: View {
    let icon: [[CGPoint]]
    let title: String
    let subtitle: String
    let hint: String
    let hintOK: Bool
    let busy: Bool
    let primaryTitle: String
    let primaryEnabled: Bool
    let focusID: AnyHashable?
    let onClose: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var bodyHeight: CGFloat = 0

    var body: some View {
        let phone = sizeClass != .regular
        let radius: CGFloat = phone ? 18 : 20
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                head(phone)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: phone ? 12 : 14) { content() }
                            .padding(.top, phone ? 2 : 4)
                            .padding(.horizontal, phone ? 18 : 24)
                            .padding(.bottom, phone ? 14 : 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { g in Color.clear.preference(key: CPSBodyHeight.self, value: g.size.height) })
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxHeight: bodyHeight > 0 ? bodyHeight : nil)
                    .onPreferenceChange(CPSBodyHeight.self) { bodyHeight = $0 }
                    .onChange(of: focusID) { id in
                        // the keyboard leaves little room: bring the field being typed in into view inside the panel
                        guard let id else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                        }
                    }
                }
                foot(phone)
            }
            .background(Theme.soul)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(alignment: .top) {
                LinearGradient(colors: [Theme.gold.opacity(0), Theme.gold, Theme.gold.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2).clipShape(Capsule()).opacity(0.8)
                    .padding(.horizontal, 22)
                    .allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(CPS.edge, lineWidth: 1))
            .shadow(color: CPS.shadow, radius: 22, y: 18)
            .frame(maxWidth: 600)
            .padding(.horizontal, phone ? 8 : 12)
            .padding(.bottom, phone ? 8 : 10)
            .padding(.top, 8)
            .layoutPriority(1) // the panel takes the room it needs first; the space above it gets what is left
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.soul.ignoresSafeArea())
    }

    private func head(_ phone: Bool) -> some View {
        HStack(spacing: 12) {
            cpsIcon(icon, size: 19, width: 2.2, color: Theme.gold)
                .frame(width: 36, height: 36)
                .background(Theme.gold.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.gold.opacity(0.35), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16.5, weight: .bold)).tracking(0.08).foregroundStyle(CPS.title).lineLimit(1)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Button(action: onClose) {
                cpsIcon(CPSIcon.close, size: 16, width: 2.2, color: Theme.faint)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chat.close"))
        }
        .padding(.top, phone ? 16 : 20)
        .padding(.trailing, phone ? 14 : 20)
        .padding(.bottom, phone ? 10 : 12)
        .padding(.leading, phone ? 18 : 24)
    }

    @ViewBuilder private func foot(_ phone: Bool) -> some View {
        let hintText = Text(hint).font(.system(size: 13)).foregroundStyle(hintOK ? Theme.buy : Theme.faint)
            .lineLimit(1).truncationMode(.tail)
        Group {
            if phone {
                VStack(alignment: .leading, spacing: 10) {
                    hintText.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        cancelButton(fill: true)
                        primaryButton(fill: true)
                    }
                }
                .padding(.top, 12).padding(.horizontal, 18).padding(.bottom, 14)
            } else {
                HStack(spacing: 10) {
                    hintText.frame(maxWidth: .infinity, alignment: .leading)
                    cancelButton(fill: false)
                    primaryButton(fill: false)
                }
                .padding(.top, 14).padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(CPS.rule).frame(height: 1) }
    }

    private func cancelButton(fill: Bool) -> some View {
        Button(action: onClose) {
            Text(NSLocalizedString("grp.cancel", comment: ""))
                .font(.system(size: 14.5, weight: .bold)).foregroundStyle(Theme.muted).lineLimit(1)
                .padding(.horizontal, fill ? 12 : 20)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: 44)
                .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
    }

    private func primaryButton(fill: Bool) -> some View {
        Button(action: onPrimary) {
            Text(primaryTitle)
                .font(.system(size: 14.5, weight: .bold)).foregroundStyle(Theme.onAccent).lineLimit(1)
                .padding(.horizontal, fill ? 12 : 20)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: 44)
                .background(
                    // the app's send button: --tf-bg-send, a radial gradient from 40% 25% out to the farthest corner
                    GeometryReader { g in
                        RadialGradient(colors: [Theme.hex(0x14D6E2), Theme.hex(0x04AEC4), Theme.hex(0x047D95)],
                                       center: UnitPoint(x: 0.4, y: 0.25), startRadius: 0,
                                       endRadius: max(1, hypot(g.size.width * 0.6, g.size.height * 0.75)))
                    }
                    .clipShape(Capsule())
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(primaryEnabled ? 0.25 : 0), lineWidth: 1).mask(
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                .shadow(color: Theme.hex(0x00C8DC, primaryEnabled ? 0.28 : 0), radius: 9, y: 4)
                .contentShape(Capsule())
        }
        .buttonStyle(CPSPress())
        .disabled(!primaryEnabled)
        .opacity(primaryEnabled ? 1 : 0.4)
    }
}

// MARK: group post comments (groups/CommentsPanel.tsx)

struct CommentsSheet: View {
    let token: String
    let groupID: String
    let postID: String
    let me: String
    let isAdmin: Bool
    let names: [String: String]
    @Environment(\.dismiss) private var dismiss
    @State private var items: [GroupComment] = []
    @State private var text = ""
    @State private var replyTo: GroupComment?
    @State private var loading = true
    @State private var posting = false
    @State private var postFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("comments.discussion").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint).textCase(.uppercase)
                        if !loading && items.isEmpty {
                            Text("comments.empty").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 20)
                        }
                        ForEach(items) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(c.sender_id == me ? NSLocalizedString("chat.you", comment: "") : (names[c.sender_id] ?? "…"))
                                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                                    if let d = serverDate(c.created_at) { Text(ChatRow.timeLabel(d)).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                                }
                                if let r = c.reply_to_id, !r.isEmpty, let parent = items.first(where: { $0.id == r }) {
                                    Text(parent.body).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                                        .padding(.leading, 6).overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
                                }
                                Text(c.body).font(.system(size: 15)).foregroundStyle(Theme.text)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button { replyTo = c } label: { Label("chat.reply", systemImage: "arrowshape.turn.up.left") }
                                if c.sender_id == me || isAdmin {
                                    Button(role: .destructive) {
                                        Task {
                                            try? await APIClient.shared.chDeleteComment(token: token, groupID: groupID, commentID: c.id)
                                            await load()
                                        }
                                    } label: { Label("chat.delete.me", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .scrollDismissesKeyboard(.interactively)
                VStack(spacing: 6) {
                    if let r = replyTo {
                        HStack {
                            Text(r.body).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                            Spacer()
                            Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
                                .accessibilityLabel(Text("chat.close"))
                        }
                    }
                    if postFailed {
                        Text("chat.action.failed").font(.system(size: 12)).foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        TextField("comments.write", text: $text, axis: .vertical).lineLimit(1...4).foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 22))
                            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.borderStrong, lineWidth: 1))
                        Button {
                            Task {
                                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !t.isEmpty, !posting else { return }
                                posting = true
                                postFailed = false
                                text = ""
                                do {
                                    try await APIClient.shared.chAddComment(token: token, groupID: groupID, postID: postID, body: t, replyTo: replyTo?.id ?? "")
                                    replyTo = nil
                                } catch {
                                    // not posted: the words come back to try again, never lost
                                    if text.isEmpty { text = t }
                                    postFailed = true
                                }
                                posting = false
                                await load()
                            }
                        } label: {
                            Image(systemName: "paperplane.fill").foregroundStyle(.white).frame(width: 42, height: 42).background(Theme.sendGradient, in: Circle())
                        }
                        .disabled(posting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                        .accessibilityLabel(Text("comments.post"))
                    }
                }
                .padding(10)
                .background(Theme.header)
            }
            .background(Starfield())
            .navigationTitle(Text("comments.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .tfColorScheme()
        .task { await load() }
    }

    private func load() async {
        items = (try? await APIClient.shared.chComments(token: token, groupID: groupID, postID: postID)) ?? items
        loading = false
    }
}

// MARK: call entries in the timeline (calls/CallEntryRow.tsx)

struct CallEntryRow: View {
    let message: Message
    let me: String
    let onCallBack: (() -> Void)?

    private var entry: [String: Any] {
        guard let s = message.signal, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    var body: some View {
        let outgoing = (entry["caller_id"] as? String) == me
        let status = (entry["status"] as? String) ?? ""
        let duration = Int64((entry["duration_ms"] as? Double) ?? Double((entry["duration_ms"] as? Int) ?? 0))
        let missed = !outgoing && ["missed", "canceled", "busy"].contains(status)
        HStack(spacing: 12) {
            Image(systemName: outgoing ? "phone.arrow.up.right" : (missed ? "phone.down" : "phone.arrow.down.left"))
                .font(.system(size: 16)).foregroundStyle(missed ? Theme.danger : Theme.accent)
                .frame(width: 36, height: 36).background((missed ? Theme.danger : Theme.accent).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(missed ? "callrow.missed" : (outgoing ? "callrow.out" : "callrow.in")))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(missed ? Theme.danger : Theme.text)
                Text(status == "completed" ? VoiceBubble.length(duration) : NSLocalizedString("callrow.status." + (status.isEmpty ? "ended" : status), comment: ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            if let d = message.date { Text(d, style: .time).font(.system(size: 11)).foregroundStyle(Theme.faint) }
            if let onCallBack {
                Button(action: onCallBack) {
                    Image(systemName: "phone.fill").font(.system(size: 14)).foregroundStyle(Theme.onAccent)
                        .frame(width: 34, height: 34).background(Theme.accent, in: Circle())
                }
                .accessibilityLabel(Text("callrow.back"))
            }
        }
        .padding(10)
        .frame(maxWidth: 300)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }
}

// MARK: link preview (shared/components/LinkPreview.tsx)

struct LinkPreviewCard: View {
    let token: String
    let url: String
    @State private var data: LinkPreviewData?
    @State private var image: UIImage?
    /// Previews already fetched this app session: a row scrolled back into view asks the server nothing and never jumps.
    private static var memo: [String: (LinkPreviewData?, UIImage?)] = [:]

    init(token: String, url: String) {
        self.token = token
        self.url = url
        let hit = Self.memo[url]
        _data = State(initialValue: hit?.0)
        _image = State(initialValue: hit?.1)
    }

    var body: some View {
        Group {
            if let d = data {
                Link(destination: URL(string: d.url ?? url) ?? URL(string: "https://app.tradeflor.com")!) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill().frame(height: 120).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        if let s = d.site, !s.isEmpty { Text(s).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                        if let t = d.title, !t.isEmpty { Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text).lineLimit(2) }
                        if let ds = d.description, !ds.isEmpty { Text(ds).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3) }
                    }
                    .padding(8)
                    .frame(maxWidth: 260, alignment: .leading)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
                }
            }
        }
        .task(id: url) {
            if Self.memo[url] != nil { return }
            data = await APIClient.shared.chLinkPreview(token: token, url: url)
            if let p = data?.image, !p.isEmpty, let d = await APIClient.shared.chLinkImage(token: token, path: p) { image = UIImage(data: d) }
            if Task.isCancelled { return } // left before the answer came: asked again next time
            if Self.memo.count > 300 { Self.memo.removeAll() }
            Self.memo[url] = (data, image)
        }
    }

    /// Made once: a new NSDataDetector for every text message on every chat redraw made scrolling lag.
    static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static var urlMemo: [String: String] = [:] // "" = no link; used from the views (main thread) only

    static func firstURL(in text: String) -> String? {
        if let hit = urlMemo[text] { return hit.isEmpty ? nil : hit }
        let out = linkDetector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url?.absoluteString
        if urlMemo.count > 800 { urlMemo.removeAll(keepingCapacity: true) }
        urlMemo[text] = out ?? ""
        return out
    }
}

// MARK: emoji picker (shared/components/EmojiPicker.tsx categories)

/// The emoji picker, the website's shared/components/EmojiPicker.tsx: an "Emoji" head with ✕, the Recent row and every
/// category (Trading first, its title in gold) with sticky titles, and a bar of category emoji at the bottom (grey until
/// chosen). A pick keeps the panel open so several can be added; in `single` mode (a reaction) only the first tap counts.
/// The Recent row is read when the panel opens, so nothing moves under the finger (web: same).
struct EmojiPanel: View {
    var single = false
    var bodyHeight: CGFloat = 300
    let onPick: (String) -> Void
    let onClose: () -> Void
    @State private var recent: [String] = EmojiRecents.load()
    @State private var current = ""
    @State private var picked = false

    private struct Section: Identifiable { let id: String; let key: String; let icon: String; let emoji: [String]; let gold: Bool }

    private var sections: [Section] {
        var out: [Section] = []
        if !recent.isEmpty { out.append(Section(id: "recent", key: "emoji.recent", icon: "🕘", emoji: recent, gold: false)) }
        for c in EmojiData.categories {
            out.append(Section(id: c.id, key: c.key, icon: c.icon, emoji: c.emoji, gold: c.id == "trading"))
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Text("emoji.title").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                            .frame(width: 32, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("chat.close"))
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.top, 8).padding(.bottom, 2)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { sec in
                            SwiftUI.Section {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                                    ForEach(Array(sec.emoji.enumerated()), id: \.offset) { _, e in
                                        Button { pick(e) } label: {
                                            Text(e).font(.system(size: 26)).frame(maxWidth: .infinity, minHeight: 40)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(EmojiKeyStyle())
                                        .accessibilityLabel(Text(e))
                                    }
                                }
                                .onAppear { if current.isEmpty { current = sec.id } }
                            } header: {
                                Text(LocalizedStringKey(sec.key)).font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(sec.gold ? Theme.hex(0xF3C95C) : Theme.muted)
                                    .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.hex(0x0A252F))
                                    .id(sec.id)
                                    .onAppear { current = sec.id }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .frame(height: bodyHeight)
                // the category bar: the section on screen lights up; a tap jumps to it
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(sections) { sec in
                            let on = current == sec.id
                            Button {
                                current = sec.id
                                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(sec.id, anchor: .top) }
                            } label: {
                                Text(sec.icon).font(.system(size: 19))
                                    .grayscale(on ? 0 : 0.85).opacity(on ? 1 : 0.7)
                                    .frame(minWidth: 36, minHeight: 34)
                                    .background(on ? Theme.hex(0x00D4DF, 0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(LocalizedStringKey(sec.key)))
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(minWidth: 0)
                }
                .background(Theme.hex(0x071E27))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
            }
        }
        .background(LinearGradient(colors: [Theme.hex(0x0B2833), Theme.hex(0x071F28)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hex(0x00D4DF, 0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 22, y: 18)
        .environment(\.colorScheme, .dark)
        .onAppear { current = recent.isEmpty ? (EmojiData.categories.first?.id ?? "") : "recent" }
    }

    private func pick(_ e: String) {
        if single {
            guard !picked else { return }
            picked = true
        }
        EmojiRecents.add(e)
        onPick(e)
    }
}

/// The web's emoji key: a soft turquoise press and a small press-in.
private struct EmojiKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.hex(0x00D4DF, 0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

/// The picker over the whole screen, centred on a dim backdrop (web .emoji-picker.floating): from a message's reaction
/// bar, where there is no composer to sit above. A tap outside closes it.
struct EmojiFloating: View {
    var single = true
    let onPick: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.hex(0x000B10, 0.55).ignoresSafeArea().onTapGesture(perform: onClose)
                EmojiPanel(single: single, bodyHeight: max(160, min(330, geo.size.height * 0.7 - 100)), onPick: onPick, onClose: onClose)
                    .frame(width: min(geo.size.width * 0.94, 380))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .transition(.opacity)
    }
}

/// The picker in a sheet (the status viewer's reply box): the same panel.
struct EmojiPickerSheet: View {
    var single = false
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EmojiPanel(single: single, bodyHeight: 300, onPick: onPick, onClose: { dismiss() })
            .padding(8)
            .presentationDetents([.height(400)])
            .presentationDragIndicator(.hidden)
            .background(Theme.hex(0x02121A).ignoresSafeArea())
    }
}

/// The emoji used last on this phone (up to 24, newest first): the picker's Recent row (web tf.emoji.recent).
enum EmojiRecents {
    private static let key = "tf.emoji.recent"
    static func load() -> [String] { Array((UserDefaults.standard.stringArray(forKey: key) ?? []).prefix(24)) }
    static func add(_ e: String) {
        var l = load().filter { $0 != e }
        l.insert(e, at: 0)
        UserDefaults.standard.set(Array(l.prefix(24)), forKey: key)
    }
}

// MARK: share live location sheet (location/ShareLocationSheet.tsx)

struct ShareLocationSheet: View {
    let onShare: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 15

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $minutes) {
                    Text("location.15m").tag(15)
                    Text("location.1h").tag(60)
                    Text("location.8h").tag(480)
                }
                .pickerStyle(.segmented)
                Text("location.note").font(.system(size: 13)).foregroundStyle(Theme.faint)
                Button {
                    onShare(minutes)
                    dismiss()
                } label: {
                    Text("location.share.go").bold().foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 48).background(Theme.accent, in: Capsule())
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.panel.ignoresSafeArea())
            .navigationTitle(Text("location.share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .presentationDetents([.height(260)])
        .tfColorScheme()
    }
}

/// "Today", "Yesterday", a weekday within the week, else "16 November 2026" (the website's day separators).
enum DayLabel {
    // made once: every day label made a new formatter on every chat redraw
    private static func template(_ t: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(t)
        return f
    }
    private static let weekday = template("EEEE")
    private static let dayMonth = template("dMMMM")
    private static let dayMonthYear = template("dMMMMyyyy")

    static func text(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return NSLocalizedString("calendar.today", comment: "") }
        if cal.isDateInYesterday(d) { return NSLocalizedString("time.yesterday", comment: "") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return weekday.string(from: d)
        } else if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return dayMonth.string(from: d)
        } else {
            return dayMonthYear.string(from: d)
        }
    }
}
