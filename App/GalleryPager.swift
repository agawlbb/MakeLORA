import SwiftUI
import UIKit
import ImageIO

struct GalleryPager: View {
    let outputs: [GenerationOutput]
    @Binding var selectedID: String
    @Binding var zoomed: Bool
    @EnvironmentObject private var store: GenerationStore
    var body: some View {
        GalleryPages(outputs: outputs, selectedID: $selectedID, zoomed: $zoomed) { output in
            try await store.imageData(output)
        }
        .accessibilityLabel("Generated image")
        .accessibilityHint("Pinch to zoom. Swipe between photos when fitted.")
        .accessibilityAdjustableAction { direction in
            guard let index = outputs.firstIndex(where: { $0.id == selectedID }) else { return }
            let next = direction == .increment ? index + 1 : index - 1
            if outputs.indices.contains(next) { selectedID = outputs[next].id; zoomed = false }
        }
    }
}

struct GalleryPages: UIViewControllerRepresentable {
    let outputs: [GenerationOutput]
    @Binding var selectedID: String
    @Binding var zoomed: Bool
    let load: (GenerationOutput) async throws -> Data
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.view.backgroundColor = .black
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.pager = controller
        context.coordinator.selectCurrent()
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.selectCurrent()
        context.coordinator.setPagingEnabled(!zoomed)
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: GalleryPages
        private var displayedIDs: [String] = []
        weak var pager: UIPageViewController?
        init(_ parent: GalleryPages) { self.parent = parent }
        func page(_ output: GenerationOutput) -> GalleryImageController {
            GalleryImageController(output: output, load: parent.load) { [weak self] zoomed in
                guard let self, (self.pager?.viewControllers?.first as? GalleryImageController)?.output.id == output.id else { return }
                self.setPagingEnabled(!zoomed)
                DispatchQueue.main.async { [weak self] in
                    guard let self, (self.pager?.viewControllers?.first as? GalleryImageController)?.output.id == output.id else { return }
                    if self.parent.zoomed != zoomed { self.parent.zoomed = zoomed }
                }
            }
        }
        func setPagingEnabled(_ enabled: Bool) {
            pager?.view.subviews.compactMap { $0 as? UIScrollView }.forEach { $0.isScrollEnabled = enabled }
        }
        func selectCurrent() {
            let ids = parent.outputs.map(\.id)
            guard let output = parent.outputs.first(where: { $0.id == parent.selectedID }) else { return }
            guard displayedIDs != ids || (pager?.viewControllers?.first as? GalleryImageController)?.output.id != output.id else { return }
            displayedIDs = ids
            pager?.setViewControllers([page(output)], direction: .forward, animated: false)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            adjacent(viewController, offset: -1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            adjacent(viewController, offset: 1)
        }
        private func adjacent(_ controller: UIViewController, offset: Int) -> UIViewController? {
            guard let controller = controller as? GalleryImageController,
                  let index = parent.outputs.firstIndex(where: { $0.id == controller.output.id }),
                  parent.outputs.indices.contains(index + offset) else { return nil }
            return page(parent.outputs[index + offset])
        }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first as? GalleryImageController else { return }
            parent.selectedID = current.output.id
            parent.zoomed = false
            current.fitImage()
            setPagingEnabled(true)
        }
    }
}

// UIScrollView supplies native pinch/pan behavior and bounds its content while zoomed.
final class GalleryImageController: UIViewController, UIScrollViewDelegate {
    let output: GenerationOutput
    private let load: (GenerationOutput) async throws -> Data
    private let onZoom: (Bool) -> Void
    let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retryButton = UIButton(type: .system)
    private var imageTask: Task<Void, Never>?
    private var loadID: UUID?
    private var previousSize: CGSize = .zero
    private var observers: [NSObjectProtocol] = []
    init(output: GenerationOutput, load: @escaping (GenerationOutput) async throws -> Data, onZoom: @escaping (Bool) -> Void) {
        self.output = output; self.load = load; self.onZoom = onZoom
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Generated image, \(output.model)"
        imageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in", target: self, selector: #selector(accessibleZoom)),
            UIAccessibilityCustomAction(name: "Fit image", target: self, selector: #selector(accessibleFit))
        ]
        scrollView.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        view.addSubview(spinner)
        retryButton.setTitle("Image unavailable — tap to retry", for: .normal)
        retryButton.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        retryButton.isHidden = true
        view.addSubview(retryButton)
        observers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.imageTask?.cancel(); self?.imageTask = nil; self?.imageView.image = nil
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.view.window != nil else { return }; self.loadImage()
            }
        ]
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        retryButton.frame = CGRect(x: 16, y: view.bounds.midY - 30, width: max(0, view.bounds.width - 32), height: 60)
        if previousSize != view.bounds.size { previousSize = view.bounds.size; fitImage() }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); loadImage() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        imageTask?.cancel(); imageTask = nil; imageView.image = nil
    }
    deinit { imageTask?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    @objc private func retryImage() { loadImage() }
    private func loadImage() {
        guard imageView.image == nil, imageTask == nil else { return }
        spinner.startAnimating(); retryButton.isHidden = true
        let id = UUID(); loadID = id
        imageTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.loadID == id { self.imageTask = nil; self.spinner.stopAnimating() } }
            do {
                let data = try await self.load(self.output)
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096
                      ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
                self.imageView.image = UIImage(cgImage: image)
                self.fitImage()
            } catch {
                if !Task.isCancelled { self.retryButton.isHidden = false }
            }
        }
    }
    func fitImage() {
        guard let image = imageView.image, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
        scrollView.minimumZoomScale = 0.001
        scrollView.maximumZoomScale = 100
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        let fit = min(scrollView.bounds.width / image.size.width, scrollView.bounds.height / image.size.height)
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = fit * 6
        scrollView.zoomScale = fit
        centerImage()
        scrollView.setContentOffset(CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top), animated: false)
        onZoom(false)
    }
    private func centerImage() {
        scrollView.contentInset = UIEdgeInsets(top: max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2), left: max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2), bottom: 0, right: 0)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale * 1.01
        // At fit size, let the outer page view own horizontal drags; pinch remains enabled.
        scrollView.panGestureRecognizer.isEnabled = zoomed
        centerImage(); onZoom(zoomed)
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale * 1.01 { scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true); return }
        let point = gesture.location(in: imageView)
        let scale = scrollView.minimumZoomScale * 2
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
    @objc private func accessibleZoom() -> Bool { scrollView.setZoomScale(scrollView.minimumZoomScale * 2, animated: true); return true }
    @objc private func accessibleFit() -> Bool { fitImage(); return true }
}
