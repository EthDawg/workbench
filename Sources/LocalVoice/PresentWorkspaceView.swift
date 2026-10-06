import AppKit
import SwiftUI
import StageKit

struct PresentWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    var body: some View { stage.scenesView }
}
