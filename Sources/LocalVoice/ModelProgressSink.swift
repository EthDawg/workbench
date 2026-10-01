/// Carries model-setup progress from the recognition engine back to the app's one model,
/// without keeping it alive. Its own file, because harnesses compile AppModel.swift by name.
final class ModelProgressSink: @unchecked Sendable {
    weak var model: AppModel?
    init(_ model: AppModel) { self.model = model }
}
