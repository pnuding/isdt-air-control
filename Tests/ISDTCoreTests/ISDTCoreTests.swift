import Testing
@testable import ISDTCore

// MARK: - Fixtures

/// Builds one 25-byte per-slot block of the A8 WorkState mega-packet.
private func slotBlock(state: UInt8, percent: UInt8 = 0, mAh: Int = 0, mWh: Int = 0, ms: Int = 0,
                       type: UInt8 = 1, currentMA: Int = 0, mV: Int = 0, ir: Int = 0, error: Int = 0) -> [UInt8] {
    func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    return [state, percent] + le(mAh, 4) + le(mWh, 4) + le(ms, 4) + [type] + le(currentMA, 4) + le(mV, 2) + le(ir, 2) + le(error, 2)
}

private func megaPacket(_ blocks: [[UInt8]]) -> TestData {
    TestData([0x31, 0xE7, UInt8(blocks.count)] + blocks.flatMap { $0 })
}

private func eightSlots(overriding overrides: [Int: [UInt8]] = [:]) -> TestData {
    megaPacket((0..<8).map { overrides[$0] ?? slotBlock(state: 0) })
}

// MARK: - Parsing

@Suite struct FrameParserTests {
    @Test func parsesMegaPacket() throws {
        let data = eightSlots(overriding: [
            2: slotBlock(state: 3, percent: 42, mAh: 1234, mWh: 4500, ms: 3_723_000, type: 1, currentMA: 500, mV: 3872, ir: 4500),
            5: slotBlock(state: 6, percent: 100, mAh: 2500, ms: 7_200_000, type: 4, currentMA: 0, mV: 1420),
        ])
        #expect(data.count == 203)
        guard case .workStates(let slots)? = FrameParser.parse(data) else {
            Issue.record("not a workStates frame"); return
        }
        #expect(slots.count == 8)

        let s3 = slots[2]
        #expect(s3.phase == .charging)
        #expect(s3.capacityPercent == 42)
        #expect(s3.chargedMAh == 1234)
        #expect(s3.energyMWh == 4500)
        #expect(s3.elapsed == 3723)
        #expect(s3.batteryType == .liIon)
        #expect(s3.currentMA == 500)
        #expect(s3.voltage == 3.872)
        #expect(abs(s3.internalResistanceMilliohm - 45) < 0.001)

        #expect(slots[5].phase == .done)
        #expect(slots[5].batteryType == .niMHCd)
        #expect(slots[0].phase == .empty) // idle with ~0 V
    }

    @Test func idleWithVoltageIsIdleNotEmpty() {
        #expect(SlotStatus.phase(forRawState: 0, voltageMV: 3700) == .idle)
        #expect(SlotStatus.phase(forRawState: 0, voltageMV: 0) == .empty)
        #expect(SlotStatus.phase(forRawState: 9, voltageMV: 3700) == .unknown(9))
    }

    @Test func rejectsTruncatedMegaPacket() {
        #expect(FrameParser.parse(eightSlots().dropLast()) == nil)
    }

    @Test func parsesElectric() {
        // 12.345 V, 1.5 A
        let data = TestData([0x31, 0xE5, 0x08, 0x39, 0x30, 0xDC, 0x05, 0x00, 0x00])
        #expect(FrameParser.parse(data) == .electric(inputMV: 12345, inputMA: 1500))
    }

    @Test func parsesSlotConfigs() {
        func block(_ task: UInt8, _ type: UInt8, _ mA: Int, _ mV: Int, _ cap: Int) -> [UInt8] {
            [task, type, UInt8(mA & 0xFF), UInt8(mA >> 8), 0, 0, UInt8(mV & 0xFF), UInt8(mV >> 8),
             UInt8(cap & 0xFF), UInt8(cap >> 8), 0, 0]
        }
        let data = TestData([0x31, 0xED, 0x02] + block(0, 1, 500, 4200, 3000) + block(0, 4, 300, 4, 0))
        guard case .slotConfigs(let configs)? = FrameParser.parse(data) else {
            Issue.record("not a slotConfigs frame"); return
        }
        #expect(configs == [
            SlotConfig(batteryType: .liIon, currentMA: 500, cutoffMV: 4200, capacityLimitMAh: 3000),
            SlotConfig(batteryType: .niMHCd, currentMA: 300, cutoffMV: 4, capacityLimitMAh: 0),
        ])
    }

    @Test func parsesWorkTaskAck() {
        #expect(FrameParser.parse(TestData([0x31, 0xEB, 0x03, 0x00])) == .workTaskAck(channel: 3, ok: true))
        #expect(FrameParser.parse(TestData([0x31, 0xEB, 0x03, 0xFF])) == .workTaskAck(channel: 3, ok: false))
    }

    @Test func ignoresForeignAndUnknownFrames() {
        #expect(FrameParser.parse(TestData([0x00, 0xE7, 0x01])) == nil)
        #expect(FrameParser.parse(TestData([0x31])) == nil)
        #expect(FrameParser.parse(TestData([0x31, 0x77, 0x00])) == .unknown(opcode: 0x77))
    }

    @Test func parsesHardwareInfo() {
        let serial: [UInt8] = [0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0]
        let info = FrameParser.parseHardwareInfo(TestData([0xE1, 1, 2, 3, 4] + serial))
        #expect(info == HardwareInfo(hardwareVersion: "1.2", firmwareVersion: "3.4", serialNumber: "305419896"))

        // Header-prefixed variant.
        #expect(FrameParser.parseHardwareInfo(TestData([0x31, 0xE1, 1, 2, 3, 4] + serial))?.firmwareVersion == "3.4")

        // Model name instead of a serial, and the all-zero placeholder, are not serials.
        let text = Array("C4Air   ".utf8)
        #expect(FrameParser.parseHardwareInfo(TestData([0xE1, 1, 0, 1, 0] + text))?.serialNumber == nil)
        #expect(FrameParser.parseHardwareInfo(TestData([0xE1, 1, 0, 1, 0] + [UInt8](repeating: 0, count: 8)))?.serialNumber == nil)
    }

    @Test func parsesBindResult() {
        #expect(FrameParser.parseBindResult(TestData([0x19, 0x00])) == 0)
        #expect(FrameParser.parseBindResult(TestData([0x19, 0x01])) == 1)
        #expect(FrameParser.parseBindResult(TestData([0xE1, 0x00])) == nil)
    }
}

// MARK: - Commands

@Suite struct CommandTests {
    @Test func buildsWorkTask() {
        let config = SlotConfig(batteryType: .liIon, currentMA: 500, cutoffMV: 4200, capacityLimitMAh: 3000)
        let bytes = [UInt8](Command.workTask(channel: 2, config: config))
        #expect(bytes == [
            0x13, 0xEA, 0x02, 0x00, 0x01, 0x00, // header, slot, task=charge, type=Li-ion, link
            0xF4, 0x01, 0x00, 0x00,             // 500 mA
            0x00,                               // cells auto
            0x68, 0x10,                         // 4200 mV
            0xB8, 0x0B, 0x00, 0x00,             // 3000 mAh
        ])
    }

    @Test func autoSendsZeros() {
        let bytes = [UInt8](Command.workTask(channel: 0, config: SlotConfig(batteryType: .auto, currentMA: 700, cutoffMV: 4200, capacityLimitMAh: 3000)))
        #expect(bytes == [0x13, 0xEA, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func buildsBind() {
        let uuid = TestData((0..<16).map { UInt8($0) })
        let bytes = [UInt8](Command.bind(clientUUID: uuid))
        #expect(bytes.count == 19)
        #expect(bytes.first == 0x18)
        #expect(Array(bytes[1..<17]) == (0..<16).map { UInt8($0) })
        #expect(Array(bytes.suffix(2)) == [0x00, 0x01])
    }
}

// MARK: - Settings validation

@Suite struct SlotConfigTests {
    @Test func defaultsAreValid() {
        for type in BatteryType.allCases {
            #expect(SlotConfig.defaults(for: type).isValid, "\(type)")
        }
    }

    @Test func validationCatchesOutOfRange() {
        var c = SlotConfig.defaults(for: .liIon)
        c.currentMA = 50
        #expect(!c.isValid)
        c = .defaults(for: .liIon)
        c.cutoffMV = 4500
        #expect(!c.isValid)
        c = .defaults(for: .liIon)
        c.capacityLimitMAh = 1500
        #expect(!c.isValid)
        c.capacityLimitMAh = 0
        #expect(c.isValid)
    }

    @Test func zeroCurrentMeansChargerDefaultAndIsValid() {
        // Observed on a real A8 Air: every slot reports 0 mA while charging at ~500 mA.
        var c = SlotConfig.defaults(for: .liIon)
        c.currentMA = 0
        #expect(c.isValid)
        #expect(c.usesDefaultCurrent)
        c.currentMA = 50
        #expect(!c.isValid)
    }

    @Test func switchingChemistryKeepsCurrentResetsRest() {
        var c = SlotConfig.defaults(for: .liIon)
        c.currentMA = 800
        c.capacityLimitMAh = 3000
        let next = c.switching(to: .niMHCd)
        #expect(next.batteryType == .niMHCd)
        #expect(next.currentMA == 800)
        #expect(next.cutoffMV == 4)
        #expect(next.capacityLimitMAh == 0)
        // Coming back from Auto (0 mA) falls back to the default current.
        #expect(SlotConfig.defaults(for: .auto).switching(to: .liFe).currentMA == 300)
    }

    @Test func matchesIgnoresUnusedFields() {
        let a = SlotConfig(batteryType: .auto, currentMA: 0, cutoffMV: 0, capacityLimitMAh: 0)
        let b = SlotConfig(batteryType: .auto, currentMA: 500, cutoffMV: 4200, capacityLimitMAh: 3000)
        #expect(a.matches(b))
        let c = SlotConfig(batteryType: .liIon15V, currentMA: 300, cutoffMV: 0, capacityLimitMAh: 0)
        let d = SlotConfig(batteryType: .liIon15V, currentMA: 300, cutoffMV: 1234, capacityLimitMAh: 0)
        #expect(c.matches(d))
        #expect(!c.matches(SlotConfig(batteryType: .liIon15V, currentMA: 400, cutoffMV: 0, capacityLimitMAh: 0)))
    }
}

// MARK: - Advertisement

@Suite struct AdvertisementTests {
    @Test func detectsA8Air() {
        // company ID BA AB, magic AF FA, model 01 0F 00 A8
        let ad = Advertisement.parse(manufacturerData: TestData([0xBA, 0xAB, 0xAF, 0xFA, 0x01, 0x0F, 0x00, 0xA8]))
        #expect(ad?.modelID == "010f00a8")
        #expect(ad?.isA8Air == true)
    }

    @Test func a4AirIsNotA8() {
        let ad = Advertisement.parse(manufacturerData: TestData([0xBA, 0xAB, 0xAF, 0xFA, 0x01, 0x0F, 0x00, 0x00]))
        #expect(ad?.modelName == "A4 Air")
        #expect(ad?.isA8Air == false)
    }

    @Test func fallsBackToEmbeddedName() {
        let ad = Advertisement.parse(manufacturerData: TestData([0xBA, 0xAB, 0xAF, 0xFA, 0x7F, 0x7F, 0x00, 0x00] + Array("A8Air".utf8) + [0]))
        #expect(ad?.isA8Air == true)
    }

    @Test func rejectsOtherVendors() {
        #expect(Advertisement.parse(manufacturerData: TestData([0x4C, 0x00, 0x02, 0x15, 0, 0, 0, 0])) == nil)
        #expect(Advertisement.parse(manufacturerData: nil) == nil)
    }
}

// MARK: - Reassembly

@Suite struct FrameAssemblerTests {
    @Test func passesWholeFramesThrough() {
        var assembler = FrameAssembler()
        let frame = eightSlots()
        #expect(assembler.push(frame) == [frame])
    }

    @Test func reassemblesFragmentedMegaPacket() {
        var assembler = FrameAssembler()
        let frame = eightSlots(overriding: [3: slotBlock(state: 3, percent: 55, mV: 3900)])
        let t = TestDate()
        #expect(assembler.push(frame.prefix(20), now: t).isEmpty)
        #expect(assembler.push(frame.dropFirst(20).prefix(100), now: t).isEmpty)
        let out = assembler.push(frame.dropFirst(120), now: t)
        #expect(out == [frame])
        guard case .workStates(let slots)? = FrameParser.parse(out[0]) else {
            Issue.record("reassembled frame didn't parse"); return
        }
        #expect(slots[3].capacityPercent == 55)
    }

    @Test func dropsStaleFragments() {
        var assembler = FrameAssembler()
        let frame = eightSlots()
        let t = TestDate()
        #expect(assembler.push(frame.prefix(20), now: t).isEmpty)
        // 5 s later a fresh, whole frame arrives; the dead fragment must not swallow it.
        let later = t.addingTimeInterval(5)
        #expect(assembler.push(frame, now: later) == [frame])
    }

    @Test func shortAcksAreNotBuffered() {
        var assembler = FrameAssembler()
        let ack = TestData([0x31, 0xEB, 0x03, 0x00])
        #expect(assembler.push(ack) == [ack])
    }
}

// MARK: - Completion detection

@Suite struct CompletionDetectorTests {
    private func snapshot(_ phases: [ChargePhase]) -> [SlotStatus] {
        phases.enumerated().map { SlotStatus(slot: $0.offset, phase: $0.element) }
    }

    @Test func firstSnapshotNeverNotifies() {
        var d = CompletionDetector()
        #expect(d.ingest(snapshot([.done, .error, .charging])).isEmpty)
    }

    @Test func reportsChargingToDone() {
        var d = CompletionDetector()
        _ = d.ingest(snapshot([.charging, .constantVoltage, .idle]))
        let events = d.ingest(snapshot([.done, .constantVoltage, .idle]))
        #expect(events == [.finished(slot: 0)])
        // Stays done: no repeat.
        #expect(d.ingest(snapshot([.done, .done, .idle])) == [.finished(slot: 1)])
        #expect(d.ingest(snapshot([.done, .done, .idle])).isEmpty)
    }

    @Test func removingBatteryIsNotCompletion() {
        var d = CompletionDetector()
        _ = d.ingest(snapshot([.charging]))
        #expect(d.ingest(snapshot([.empty])).isEmpty)
    }

    @Test func reportsNewErrorsOnce() {
        var d = CompletionDetector()
        _ = d.ingest(snapshot([.charging]))
        #expect(d.ingest(snapshot([.error])) == [.failed(slot: 0)])
        #expect(d.ingest(snapshot([.error])).isEmpty)
    }

    @Test func survivesGapsInSlotList() {
        // A partial snapshot (e.g. a reconnect) must not erase memory of other slots.
        var d = CompletionDetector()
        _ = d.ingest(snapshot([.charging, .charging]))
        #expect(d.ingest([SlotStatus(slot: 1, phase: .done)]) == [.finished(slot: 1)])
        #expect(d.ingest([SlotStatus(slot: 0, phase: .done)]) == [.finished(slot: 0)])
    }
}

// MARK: - Notification wording

@Suite struct ChargeMessagesTests {
    private func slots(_ build: (inout [SlotStatus]) -> Void) -> [SlotStatus] {
        var all = (0..<8).map { SlotStatus(slot: $0) }
        build(&all)
        return all
    }

    @Test func singleCompletionDescribesTheCharge() {
        let all = slots {
            $0[2] = SlotStatus(slot: 2, phase: .done, chargedMAh: 2487, elapsed: 2 * 3600 + 41 * 60,
                               rawBatteryType: BatteryType.liIon.rawValue, voltageMV: 4190)
            $0[0].phase = .charging
        }
        let message = ChargeMessages.completion(finished: [2], slots: all)
        #expect(message.title == "Slot 3 is fully charged")
        #expect(message.body == "Li-ion · 2487 mAh in 2h 41m · 4.19 V")
    }

    @Test func lastOneOutSaysAllFinished() {
        let all = slots {
            $0[2] = SlotStatus(slot: 2, phase: .done, chargedMAh: 1000, elapsed: 600, rawBatteryType: 6, voltageMV: 4200)
        }
        let message = ChargeMessages.completion(finished: [2], slots: all)
        #expect(message.body == "1000 mAh in 10m · 4.20 V. All slots are finished.")
    }

    @Test func severalCompletionsAreGroupedIntoOneMessage() {
        let all = slots {
            $0[0] = SlotStatus(slot: 0, phase: .done, chargedMAh: 1500)
            $0[3] = SlotStatus(slot: 3, phase: .done, chargedMAh: 2200)
            $0[5] = SlotStatus(slot: 5, phase: .done, chargedMAh: 900)
            $0[7].phase = .charging
        }
        let message = ChargeMessages.completion(finished: [5, 0, 3], slots: all)
        #expect(message.title == "Slots 1, 4 and 6 are fully charged")
        #expect(message.body == "Slot 1: 1500 mAh, Slot 4: 2200 mAh, Slot 6: 900 mAh")
    }

    @Test func errorMessageIncludesCodes() {
        let all = slots { $0[1] = SlotStatus(slot: 1, phase: .error, errorCode: 7) }
        let message = ChargeMessages.error(failed: [1], slots: all)
        #expect(message.title == "Slot 2 reported an error")
        #expect(message.body == "Slot 2: code 7")
        #expect(ChargeMessages.error(failed: [0], slots: all).body == "Check the battery and the contacts.")
    }

    @Test func formatsLists() {
        #expect(ChargeMessages.slotList([4]) == "Slot 5")
        #expect(ChargeMessages.slotList([2, 0]) == "Slots 1 and 3")
        #expect(ChargeMessages.duration(59) == "0m")
        #expect(ChargeMessages.duration(3600 + 5 * 60) == "1h 5m")
    }
}

// MARK: - Charger kinds (A8 / A4 / C4)

@Suite struct ChargerKindTests {
    private func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    /// A per-channel WorkState reply as the A4/C4 send it (42 bytes).
    private func channelWorkState(channel: Int, state: UInt8, percent: UInt8, mAh: Int, ms: Int, type: UInt8,
                                  fullMV: Int, currentMA: Int, capacity: Int, error: Int = 0) -> TestData {
        var b = [UInt8](repeating: 0, count: 42)
        b[0] = 0x31; b[1] = 0xE7; b[2] = UInt8(channel); b[3] = state; b[4] = percent
        b.replaceSubrange(5..<9, with: le(mAh, 4))
        b.replaceSubrange(13..<17, with: le(ms, 4))
        b[17] = type
        b.replaceSubrange(20..<22, with: le(fullMV, 2))
        b.replaceSubrange(22..<26, with: le(currentMA, 4))
        b.replaceSubrange(32..<36, with: le(capacity, 4))
        b.replaceSubrange(36..<38, with: le(error, 2))
        return TestData(b)
    }

    @Test func modelsDescribeTheirHardware() {
        #expect(ChargerKind.a8Air.channelCount == 8)
        #expect(ChargerKind.a4Air.channelCount == 4)
        #expect(ChargerKind.c4Air.channelCount == 6)
        #expect(ChargerKind.a8Air.usesMegaPacket)
        #expect(!ChargerKind.a4Air.usesMegaPacket && !ChargerKind.c4Air.usesMegaPacket)
        #expect(ChargerKind.c4Air.currentRange.upperBound == 2000)
        #expect(ChargerKind(modelName: "C4 Air") == .c4Air)
        #expect(ChargerKind(modelName: "Air 8") == nil)
    }

    @Test func a4SlotsAreReversedRelativeToChannels() {
        #expect(ChargerKind.a4Air.channel(forSlot: 0) == 3)
        #expect(ChargerKind.a4Air.slot(forChannel: 3) == 0)
        #expect(ChargerKind.a8Air.channel(forSlot: 5) == 5)
        for slot in 0..<4 { #expect(ChargerKind.a4Air.slot(forChannel: ChargerKind.a4Air.channel(forSlot: slot)) == slot) }
    }

    @Test func advertisementMapsToKinds() {
        let a4 = Advertisement.parse(manufacturerData: TestData([0xBA, 0xAB, 0xAF, 0xFA, 0x01, 0x0F, 0x00, 0x00]))
        #expect(a4?.chargerKind == .a4Air)
        let c4 = Advertisement.parse(manufacturerData: TestData([0xBA, 0xAB, 0xAF, 0xFA, 0x01, 0x07, 0x00, 0x00]))
        #expect(c4?.chargerKind == .c4Air)
        let a8 = Advertisement.parse(manufacturerData: TestData([0xBA, 0xAB, 0xAF, 0xFA, 0x01, 0x0F, 0x00, 0xA8]))
        #expect(a8?.chargerKind == .a8Air)
        let k2 = Advertisement.parse(manufacturerData: TestData([0xBA, 0xAB, 0xAF, 0xFA, 0x01, 0x04, 0x00, 0x00]))
        #expect(k2?.chargerKind == nil)
    }

    @Test func parsesChannelWorkStateWithSettings() {
        let data = channelWorkState(channel: 2, state: 4, percent: 87, mAh: 2100, ms: 5_400_000, type: 1,
                                    fullMV: 4200, currentMA: 1500, capacity: 3000, error: 0)
        guard case .channelWorkState(let ws)? = FrameParser.parse(data, kind: .c4Air) else {
            Issue.record("not a channel work state"); return
        }
        #expect(ws.channel == 2)
        #expect(ws.capacityPercent == 87)
        #expect(ws.elapsed == 5400)
        #expect(ws.config == SlotConfig(batteryType: .liIon, currentMA: 1500, cutoffMV: 4200, capacityLimitMAh: 3000))

        let status = ws.status(slot: 2, voltageMV: 4150, currentMA: 480)
        #expect(status.phase == .constantVoltage)
        #expect(status.voltageMV == 4150 && status.currentMA == 480)
    }

    @Test func sameBytesParseDifferentlyPerFamily() {
        // Byte 2 is "number of channels" to the A8 but a channel index to the A4/C4, so the same
        // bytes must be interpreted per family, never guessed.
        let data = channelWorkState(channel: 1, state: 3, percent: 10, mAh: 5, ms: 1000, type: 4, fullMV: 5, currentMA: 500, capacity: 0)
        if case .workStates? = FrameParser.parse(data, kind: .a8Air) {} else { Issue.record("A8 should read the mega-packet layout") }
        if case .channelWorkState? = FrameParser.parse(data, kind: .a4Air) {} else { Issue.record("A4 should parse per-channel") }
    }

    @Test func parsesElectricShortAndLong() {
        // Short: input 5.0 V / 1.2 A, output 1.42 V, charge 500 mA.
        var shortBytes: [UInt8] = [0x31, 0xE5, 0x01]
        shortBytes += le(5000, 2)
        shortBytes += le(1200, 4)
        shortBytes += le(1420, 2)
        shortBytes += le(500, 4)
        shortBytes += [UInt8](repeating: 0, count: 8)
        let expectedShort = Frame.channelElectric(channel: 1, inputMV: 5000, inputMA: 1200, outputMV: 1420, chargeMA: 500)
        #expect(FrameParser.parse(TestData(shortBytes), kind: .c4Air) == expectedShort)

        // Long (> 35 bytes): 4-byte fields.
        var longBytes: [UInt8] = [0x31, 0xE5, 0x03]
        longBytes += le(12000, 4)
        longBytes += le(2000, 4)
        longBytes += le(4100, 4)
        longBytes += le(900, 4)
        longBytes += [UInt8](repeating: 0, count: 22)
        #expect(longBytes.count > 35)
        let expectedLong = Frame.channelElectric(channel: 3, inputMV: 12000, inputMA: 2000, outputMV: 4100, chargeMA: 900)
        #expect(FrameParser.parse(TestData(longBytes), kind: .c4Air) == expectedLong)

        // The A8's 9-byte reply stays input-only.
        let a8Reply: [UInt8] = [0x31, 0xE5, 0x08, 0x39, 0x30, 0xDC, 0x05, 0x00, 0x00]
        #expect(FrameParser.parse(TestData(a8Reply)) == Frame.electric(inputMV: 12345, inputMA: 1500))
    }

    @Test func perChannelWorkStateIsNotReassembledLikeTheMegaPacket() {
        var assembler = FrameAssembler(kind: .c4Air)
        let frame = channelWorkState(channel: 1, state: 3, percent: 10, mAh: 5, ms: 1000, type: 4, fullMV: 5, currentMA: 500, capacity: 0)
        #expect(assembler.push(frame) == [frame])
    }

    @Test func c4ShowsWhicheverBayLayoutHoldsBatteries() {
        func slots(_ populated: [Int]) -> [SlotStatus] {
            (0..<6).map { SlotStatus(slot: $0, phase: populated.contains($0) ? .charging : .empty) }
        }
        var large = false
        #expect(ChargerKind.c4Air.visibleSlots(in: slots([0, 2]), c4UsesLargeBays: &large) == [0, 1, 2, 3])
        #expect(!large)
        #expect(ChargerKind.c4Air.visibleSlots(in: slots([4]), c4UsesLargeBays: &large) == [4, 5])
        #expect(large)
        // Nothing inserted: keep the last layout instead of flipping back.
        #expect(ChargerKind.c4Air.visibleSlots(in: slots([]), c4UsesLargeBays: &large) == [4, 5])
        // Small bays win when both look populated (the layouts are mutually exclusive).
        #expect(ChargerKind.c4Air.visibleSlots(in: slots([1, 5]), c4UsesLargeBays: &large) == [0, 1, 2, 3])
        #expect(ChargerKind.a4Air.visibleSlots(in: slots([]), c4UsesLargeBays: &large) == [0, 1, 2, 3])
        #expect(ChargerKind.a8Air.visibleSlots(in: slots([]), c4UsesLargeBays: &large).count == 8)
    }

    @Test func c4AllowsHigherCurrents() {
        var c = SlotConfig.defaults(for: .liIon)
        c.currentMA = 1800
        #expect(!c.issues(currentRange: ChargerKind.a8Air.currentRange).isEmpty)
        #expect(c.issues(currentRange: ChargerKind.c4Air.currentRange).isEmpty)
        #expect(c.switching(to: .liFe, currentRange: ChargerKind.c4Air.currentRange).currentMA == 1800)
        #expect(c.switching(to: .liFe, currentRange: ChargerKind.a8Air.currentRange).currentMA == 1000)
    }
}
