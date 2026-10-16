import Foundation
import SonoFerryCore

@main struct HeadsetSoundViewTests {
    @MainActor static func main() throws {
        var state = HeadsetSnapshot(address: "00:11:22:33:44:55")
        let curve = HeadsetEQ(id: 10, name: "Offline EQ", minimum: -6, maximum: 6, frequencies: [80,900,12000], gains: [0,1,2])
        let request = EQEditorRequest(curve: curve, snapshot: state)
        precondition(request.matches(state))
        state.generation = UUID()
        precondition(!request.matches(state), "reconnect must invalidate old editor/delete context")
        state.generation = request.generation; state.address = "00:11:22:33:44:66"
        precondition(!request.matches(state), "another device must never receive an old draft/delete")
        precondition(!request.matches(nil))
        var slider = BassWaveSliderState()
        precondition(slider.displayed(0) == 0)
        slider.changed(3)
        precondition(slider.displayed(0) == 3 && slider.release(actual: 0) == 3 && slider.waiting)
        precondition(slider.displayed(0) == 3, "pre-write baseline must not move a released thumb back")
        precondition(slider.displayed(2) == 3, "hold target through intermediate notifications until operation ends")
        slider.changed(-5)
        precondition(slider.displayed(0) == 3 && slider.release(actual: 0) == nil, "pending adjustment cannot write twice")
        slider.reset()
        precondition(slider.displayed(2) == 2 && !slider.waiting, "terminal mismatched readback is authoritative")
        slider.changed(2)
        precondition(slider.release(actual: 2) == nil && !slider.waiting, "unchanged value never writes")
        slider.changed(-2); _ = slider.release(actual: 2); slider.reset()
        precondition(slider.displayed(4) == 4, "rejected request, disconnect or device change clears optimistic state")
        print("HEADSET_BASS_SLIDER PASS: no snapback, pending single write, authoritative readback and reset")
        print("HEADSET_EDITOR_CONTEXT PASS: editor and delete requests remain bound to their opening device/generation")
    }
}
