import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Фото с применённым кропом (оригинал не трогаем)
struct CroppedImage: View {
    let image: UIImage
    var scale: Double, x: Double, y: Double

    var body: some View {
        GeometryReader { geo in
            let fill = FeedLayout.fill(image.size, in: geo.size)
            Image(uiImage: image).resizable()
                .frame(width: fill.width * scale, height: fill.height * scale)
                .position(x: geo.size.width / 2 + x * geo.size.width,
                          y: geo.size.height / 2 + y * geo.size.height)
        }
        .clipped()
    }
}

struct FeedGridView: View {
    @Environment(\.modelContext) private var context
    let account: Account

    @State private var editing: FeedPost?
    @State private var draggedPost: FeedPost?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedPost: FeedPost?
    @State private var selectedRemotePost: FeedPost?
    @State private var library = PhotoLibraryBrowser()
    @State private var selectedAssetID: PhotoLibraryAsset.ID?
    @State private var suppressNextGallerySelection = false
    @State private var galleryExpanded = false
    @State private var undoStack: [FeedChange] = []
    @State private var redoStack: [FeedChange] = []
    @State private var cropStartState: FeedState?
    @State private var galleryScrollStartState: FeedState?
    @State private var galleryReplacementGeneration = 0
    @State private var syncing = false
    @State private var error: String?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: 3)
    private let historyLimit = 30

    private var canUndo: Bool { undoStack.isEmpty == false }

    private var canRedo: Bool { redoStack.isEmpty == false }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 1) {
                    ForEach(account.sortedPosts) { post in
                        cell(post)
                    }
                }
                if account.posts.isEmpty {
                    Text("Нажми ↻, чтобы загрузить последние 12 постов, или добавь фото из галереи")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(40)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                undoRedoControls
                    .padding(.leading, 12)

                if selectedPost?.isDraft == true {
                    mainGalleryStrip
                        .id("\(selectedPost?.id.uuidString ?? "")-\(library.selectedAlbumID ?? "")")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, selectedPost?.isDraft == true ? 0 : 12)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if syncing { ProgressView() } else {
                    Button { Task { await sync() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickerItems, matching: .images) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Добавить фото")
            }
        }
        .task {
            if account.posts.isEmpty { await sync() }
            await library.load()
        }
        .onChange(of: pickerItems) { _, items in Task { await addDrafts(items) } }
        .onChange(of: selectedAssetID) { _, id in
            guard let id, let asset = library.assets.first(where: { $0.id == id }) else { return }
            if suppressNextGallerySelection {
                suppressNextGallerySelection = false
                return
            }
            Task { await replaceSelectedPhoto(with: asset) }
        }
        .sheet(item: $editing) { post in
            CropEditorView(post: post) {
                delete(post)
                editing = nil
            }
        }
        .alert("Ошибка", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var undoRedoControls: some View {
        HStack(spacing: 10) {
            Button { undoPhotoChange() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 15, height: 15)
            }
            .disabled(!canUndo)
            .tint(canUndo ? .accentColor : .gray)
            .accessibilityLabel("Отменить")

            Button { redoPhotoChange() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 15, height: 15)
            }
            .disabled(!canRedo)
            .tint(canRedo ? .accentColor : .gray)
            .accessibilityLabel("Вернуть")
        }
        .font(.title2.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var mainGalleryStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .gesture(galleryExpansionGesture)

            HStack(spacing: 10) {
                Menu {
                    ForEach(library.albums) { album in
                        Button(album.title) {
                            Task {
                                await library.select(album)
                                selectedPost?.sourceAlbumID = album.id
                                setGalleryPosition(restoredAssetID())
                            }
                        }
                    }
                } label: {
                    Label(library.selectedAlbum?.title ?? "Недавние", systemImage: "rectangle.stack")
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 16)

            if galleryExpanded {
                expandedGalleryGrid
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                GalleryCarouselView(
                    assets: library.assets,
                    selectedID: $selectedAssetID,
                    onPreview: previewGalleryAsset,
                    onCommit: commitGalleryAsset
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white, lineWidth: 3)
                            .frame(width: 54, height: 72)
                            .allowsHitTesting(false)
                    }
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            Color.black.opacity(0.92)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .topTrailing) {
            Button { hideGallery() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.18))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.trailing, 14)
            .accessibilityLabel("Скрыть галерею")
        }
    }

    private var galleryExpansionGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                if value.translation.height < -35 {
                    withAnimation(.snappy) { galleryExpanded = true }
                } else if value.translation.height > 35 {
                    withAnimation(.snappy) { galleryExpanded = false }
                }
            }
    }

    private var expandedGalleryGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
                ForEach(library.assets) { asset in
                    Button { chooseGalleryAsset(asset) } label: {
                        if let thumb = asset.thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle().fill(.white.opacity(0.18))
                        }
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if selectedAssetID == asset.id {
                            RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(height: 340)
    }

    private func cell(_ post: FeedPost) -> some View {
        Color.clear
            .aspectRatio(FeedLayout.cellAspect, contentMode: .fit)
            .overlay {
                if let img = ImageStore.load(post.imageFile) {
                    CroppedImage(image: img, scale: post.cropScale, x: post.cropX, y: post.cropY)
                    GeometryReader { geo in
                        TwoFingerCropOverlay {
                            select(post)
                        } onBegin: {
                            beginCropHistory()
                        } onChange: { magnificationDelta, translationDelta in
                            crop(post, imageSize: img.size, frame: geo.size, magnificationDelta: magnificationDelta, translationDelta: translationDelta)
                        } onEnd: {
                            finishCropHistory()
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if post.isDraft {
                    Button(role: .destructive) { delete(post) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("Убрать фото из ленты")
                }
            }
            .overlay(alignment: .topTrailing) {
                if post.isDraft {
                    Button { editing = post } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("Редактировать кроп")
                }
            }
            .overlay {
                if selectedPost?.id == post.id || selectedRemotePost?.id == post.id {
                    Rectangle().stroke(post.isDraft ? .blue : .white, lineWidth: 3)
                }
            }
            .clipped()
            .opacity(draggedPost?.id == post.id ? 0.45 : 1)
            .onTapGesture { select(post) }
            .onDrag {
                hideGallery()
                draggedPost = post
                return NSItemProvider(object: post.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: FeedReorderDelegate(target: post, dragged: $draggedPost, move: move))
    }

    private func select(_ post: FeedPost) {
        if post.isDraft {
            selectedRemotePost = nil
            selectedPost = post
            Task {
                await library.selectAlbum(id: post.sourceAlbumID)
                setGalleryPosition(restoredAssetID(for: post))
            }
        } else {
            swapRemotePost(post)
        }
    }

    private func swapRemotePost(_ post: FeedPost) {
        selectedPost = nil
        guard let first = selectedRemotePost else {
            selectedRemotePost = post
            return
        }
        if first.id == post.id {
            selectedRemotePost = nil
            return
        }
        let before = currentFeedState()
        let firstOrder = first.order
        first.order = post.order
        post.order = firstOrder
        normalizeOrder()
        recordFeedChange(from: before, to: currentFeedState())
        selectedRemotePost = nil
    }

    private func hideGallery() {
        selectedPost = nil
        selectedRemotePost = nil
        suppressNextGallerySelection = false
    }

    private func restoredAssetID(for post: FeedPost? = nil) -> PhotoLibraryAsset.ID? {
        let post = post ?? selectedPost
        if let post,
           let rememberedID = post.sourceAssetID,
           library.assets.contains(where: { $0.id == rememberedID }) {
            return rememberedID
        }
        if let selectedAssetID, library.assets.contains(where: { $0.id == selectedAssetID }) {
            return selectedAssetID
        }
        return library.assets.first?.id
    }

    private func setGalleryPosition(_ id: PhotoLibraryAsset.ID?) {
        guard let id else { return }
        if selectedAssetID == id {
            suppressNextGallerySelection = false
        } else {
            suppressNextGallerySelection = true
            selectedAssetID = id
        }
    }

    private func chooseGalleryAsset(_ asset: PhotoLibraryAsset) {
        galleryScrollStartState = nil
        suppressNextGallerySelection = true
        selectedAssetID = asset.id
        Task { await replaceSelectedPhoto(with: asset) }
    }

    private func previewGalleryAsset(_ id: PhotoLibraryAsset.ID) {
        guard let asset = library.assets.first(where: { $0.id == id }) else { return }
        if galleryScrollStartState == nil {
            galleryScrollStartState = currentFeedState()
        }
        galleryReplacementGeneration += 1
        let generation = galleryReplacementGeneration
        suppressNextGallerySelection = true
        selectedAssetID = id
        Task { await replaceSelectedPhoto(with: asset, recordsHistory: false, expectedGalleryGeneration: generation) }
    }

    private func commitGalleryAsset(_ id: PhotoLibraryAsset.ID) {
        guard let asset = library.assets.first(where: { $0.id == id }) else { return }
        let before = galleryScrollStartState ?? currentFeedState()
        galleryScrollStartState = nil
        galleryReplacementGeneration += 1
        let generation = galleryReplacementGeneration
        suppressNextGallerySelection = true
        selectedAssetID = id
        Task {
            await replaceSelectedPhoto(with: asset, recordsHistory: false, expectedGalleryGeneration: generation)
            recordFeedChange(from: before, to: currentFeedState())
        }
    }

    private func delete(_ p: FeedPost) {
        if selectedPost?.id == p.id { selectedPost = nil }
        if selectedRemotePost?.id == p.id { selectedRemotePost = nil }
        ImageStore.delete(p.imageFile)
        context.delete(p)
        normalizeOrder()
    }

    private func move(_ dragged: FeedPost, before target: FeedPost) {
        var posts = account.sortedPosts
        guard let from = posts.firstIndex(where: { $0.id == dragged.id }),
              let to = posts.firstIndex(where: { $0.id == target.id }),
              from != to else { return }
        let before = currentFeedState()
        withAnimation(.snappy) {
            posts.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            for (index, post) in posts.enumerated() {
                post.order = index
            }
        }
        recordFeedChange(from: before, to: currentFeedState())
    }

    private func normalizeOrder() {
        for (index, post) in account.sortedPosts.enumerated() {
            post.order = index
        }
    }

    private func replaceSelectedPhoto(with asset: PhotoLibraryAsset, recordsHistory: Bool = true, expectedGalleryGeneration: Int? = nil) async {
        guard let post = selectedPost, post.isDraft else { return }
        if post.sourceAssetID == asset.id { return }
        do {
            let before = currentFeedState()
            let selection = try await library.imageData(for: asset)
            if let expectedGalleryGeneration, expectedGalleryGeneration != galleryReplacementGeneration { return }
            guard let file = ImageStore.save(selection.data) else {
                error = "Не удалось сохранить выбранное фото"
                return
            }
            post.imageFile = file
            post.sourceFilename = selection.filename
            post.sourceAssetID = asset.id
            post.sourceAlbumID = library.selectedAlbumID
            post.cropScale = 1
            post.cropX = 0
            post.cropY = 0
            if recordsHistory {
                recordFeedChange(from: before, to: currentFeedState())
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func undoPhotoChange() {
        guard let change = undoStack.popLast() else { return }
        apply(change.before)
        redoStack.append(change)
    }

    private func redoPhotoChange() {
        guard let change = redoStack.popLast() else { return }
        apply(change.after)
        undoStack.append(change)
    }

    private func recordFeedChange(from before: FeedState, to after: FeedState) {
        guard let change = FeedChange(before: before, after: after) else { return }
        undoStack.append(change)
        if undoStack.count > historyLimit {
            undoStack.removeFirst(undoStack.count - historyLimit)
        }
        redoStack = []
    }

    private func currentFeedState() -> FeedState {
        FeedState(posts: account.sortedPosts)
    }

    private func apply(_ states: [FeedPostState]) {
        for postState in states {
            apply(postState)
        }
    }

    private func apply(_ state: FeedPostState) {
        let post = state.post
        post.order = state.order
        post.imageFile = state.imageFile
        post.sourceFilename = state.sourceFilename
        post.sourceAssetID = state.sourceAssetID
        post.sourceAlbumID = state.sourceAlbumID
        post.cropScale = state.cropScale
        post.cropX = state.cropX
        post.cropY = state.cropY
        if selectedPost?.id == post.id {
            suppressNextGallerySelection = true
            selectedAssetID = state.sourceAssetID
        }
    }

    private func beginCropHistory() {
        if cropStartState == nil {
            cropStartState = currentFeedState()
        }
    }

    private func finishCropHistory() {
        guard let before = cropStartState else { return }
        cropStartState = nil
        recordFeedChange(from: before, to: currentFeedState())
    }

    private func crop(_ post: FeedPost, imageSize: CGSize, frame: CGSize, magnificationDelta: CGFloat, translationDelta: CGPoint) {
        post.cropScale = min(max(post.cropScale * Double(magnificationDelta), 1), 5)
        post.cropX += Double(translationDelta.x / frame.width)
        post.cropY += Double(translationDelta.y / frame.height)
        limitCrop(post, imageSize: imageSize, frame: frame)
    }

    private func limitCrop(_ post: FeedPost, imageSize: CGSize, frame: CGSize) {
        let fill = FeedLayout.fill(imageSize, in: frame)
        let mx = max(0, (fill.width * post.cropScale - frame.width) / 2 / frame.width)
        let my = max(0, (fill.height * post.cropScale - frame.height) / 2 / frame.height)
        post.cropX = min(max(post.cropX, -mx), mx)
        post.cropY = min(max(post.cropY, -my), my)
    }

    // MARK: Черновики из галереи (ставятся в начало ленты)
    private func addDrafts(_ items: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        var new: [FeedPost] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let file = ImageStore.save(data) else { continue }
            let fallbackName = item.itemIdentifier.map { "\($0).jpg" }
            new.append(FeedPost(order: 0, imageFile: file, sourceFilename: fallbackName))
        }
        let all = new + account.sortedPosts
        new.forEach { $0.account = account; context.insert($0) }
        for (i, p) in all.enumerated() { p.order = i }
    }

    // MARK: Синхронизация с Instagram
    private func sync() async {
        let key = account.id.uuidString
        syncing = true; defer { syncing = false }
        do {
            let source: FeedSource
            if var token = Keychain.get(key) {          // есть токен — официальный API
                if let fresh = try? await InstagramService.refresh(token: token) {
                    token = fresh; Keychain.set(fresh, for: key)
                }
                source = GraphAPISource(token: token)
            } else {                                     // иначе публичный профиль по нику
                source = PublicProfileSource(username: account.username)
            }
            let media = try await source.latest(limit: 12)
            let ids = media.map(\.id)

            // убрать то, чего больше нет в последних 12
            for p in account.posts {
                if let id = p.igMediaId, !ids.contains(id) { delete(p) }
            }
            // добавить новые (картинки качаем и кэшируем — ссылки CDN протухают)
            let have = Set(account.posts.compactMap(\.igMediaId))
            var nextOrder = (account.posts.map(\.order).max() ?? -1) + 1
            for m in media where !have.contains(m.id) {
                guard let data = try? await InstagramService.download(m.imageURL),
                      let file = ImageStore.save(data) else { continue }
                let p = FeedPost(order: nextOrder, imageFile: file, igMediaId: m.id, caption: m.caption)
                nextOrder += 1
                p.account = account
                context.insert(p)
            }
            normalizeOrder()
        } catch { self.error = error.localizedDescription }
    }
}

struct FeedState: Equatable {
    let posts: [FeedPostState]

    @MainActor init(posts: [FeedPost]) {
        self.posts = posts.map(FeedPostState.init)
    }
}

struct FeedPostState: Equatable {
    let post: FeedPost
    let id: UUID
    let order: Int
    let imageFile: String
    let sourceFilename: String?
    let sourceAssetID: String?
    let sourceAlbumID: String?
    let cropScale: Double
    let cropX: Double
    let cropY: Double

    init(post: FeedPost) {
        self.post = post
        id = post.id
        order = post.order
        imageFile = post.imageFile
        sourceFilename = post.sourceFilename
        sourceAssetID = post.sourceAssetID
        sourceAlbumID = post.sourceAlbumID
        cropScale = post.cropScale
        cropX = post.cropX
        cropY = post.cropY
    }

    static func == (lhs: FeedPostState, rhs: FeedPostState) -> Bool {
        lhs.id == rhs.id &&
        lhs.order == rhs.order &&
        lhs.imageFile == rhs.imageFile &&
        lhs.sourceFilename == rhs.sourceFilename &&
        lhs.sourceAssetID == rhs.sourceAssetID &&
        lhs.sourceAlbumID == rhs.sourceAlbumID &&
        lhs.cropScale == rhs.cropScale &&
        lhs.cropX == rhs.cropX &&
        lhs.cropY == rhs.cropY
    }
}

struct FeedChange {
    let before: [FeedPostState]
    let after: [FeedPostState]

    init?(before: FeedState, after: FeedState) {
        let oldStates = Dictionary(uniqueKeysWithValues: before.posts.map { ($0.id, $0) })
        let newStates = Dictionary(uniqueKeysWithValues: after.posts.map { ($0.id, $0) })
        let changedIDs = after.posts.compactMap { state -> UUID? in
            guard let old = oldStates[state.id], old != state else { return nil }
            return state.id
        }
        guard changedIDs.isEmpty == false else { return nil }
        self.before = changedIDs.compactMap { oldStates[$0] }
        self.after = changedIDs.compactMap { newStates[$0] }
    }
}

struct FeedReorderDelegate: DropDelegate {
    let target: FeedPost
    @Binding var dragged: FeedPost?
    let move: (FeedPost, FeedPost) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged.id != target.id else { return }
        move(dragged, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

struct GalleryCarouselView: UIViewRepresentable {
    let assets: [PhotoLibraryAsset]
    @Binding var selectedID: PhotoLibraryAsset.ID?
    let onPreview: (PhotoLibraryAsset.ID) -> Void
    let onCommit: (PhotoLibraryAsset.ID) -> Void

    private let itemWidth: CGFloat = 54
    private let itemHeight: CGFloat = 72
    private let spacing: CGFloat = 10

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .normal
        scrollView.delegate = context.coordinator
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        let coordinator = context.coordinator
        rebuild(scrollView, coordinator: coordinator)
        DispatchQueue.main.async {
            coordinator.parent = self
            rebuild(scrollView, coordinator: coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func rebuild(_ scrollView: UIScrollView, coordinator: Coordinator) {
        let ids = assets.map(\.id)
        let boundsWidth = scrollView.bounds.width
        guard boundsWidth > 0 else { return }
        let sideInset = max(0, (boundsWidth - itemWidth) / 2)
        let contentWidth = sideInset * 2 + CGFloat(assets.count) * itemWidth + CGFloat(max(0, assets.count - 1)) * spacing

        if coordinator.renderedIDs != ids || abs(coordinator.renderedWidth - boundsWidth) > 0.5 {
            scrollView.subviews.forEach { $0.removeFromSuperview() }
            scrollView.contentInset = .zero
            scrollView.contentSize = CGSize(width: contentWidth, height: itemHeight)
            for (index, asset) in assets.enumerated() {
                let frame = CGRect(x: sideInset + CGFloat(index) * (itemWidth + spacing), y: 4, width: itemWidth, height: itemHeight)
                let imageView = UIImageView(frame: frame)
                imageView.image = asset.thumbnail
                imageView.backgroundColor = UIColor.white.withAlphaComponent(0.18)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = 6
                scrollView.addSubview(imageView)
            }
            coordinator.renderedIDs = ids
            coordinator.renderedWidth = boundsWidth
        } else {
            for (index, view) in scrollView.subviews.enumerated() where index < assets.count {
                (view as? UIImageView)?.image = assets[index].thumbnail
            }
        }

        if let selectedID, let index = assets.firstIndex(where: { $0.id == selectedID }), !coordinator.isUserScrolling {
            coordinator.center(index: index, in: scrollView, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: GalleryCarouselView
        var renderedIDs: [PhotoLibraryAsset.ID] = []
        var renderedWidth: CGFloat = 0
        var isUserScrolling = false
        private var dragStartIndex = 0
        private var lastPreviewIndex: Int?
        private var pendingSelectionIndex: Int?

        init(parent: GalleryCarouselView) {
            self.parent = parent
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
            dragStartIndex = nearestIndex(for: scrollView.contentOffset.x, in: scrollView)
            lastPreviewIndex = dragStartIndex
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isUserScrolling else { return }
            previewCenteredAsset(in: scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishScrolling(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishScrolling(scrollView) }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            commitPendingSelection()
        }

        private func finishScrolling(_ scrollView: UIScrollView) {
            let index = nearestIndex(for: scrollView.contentOffset.x, in: scrollView)
            let targetOffset = centeredOffset(for: index, in: scrollView)
            pendingSelectionIndex = index
            dragStartIndex = index
            isUserScrolling = false
            if abs(scrollView.contentOffset.x - targetOffset) < 0.5 {
                commitPendingSelection()
            } else {
                scrollView.setContentOffset(CGPoint(x: targetOffset, y: 0), animated: true)
            }
        }

        func center(index: Int, in scrollView: UIScrollView, animated: Bool) {
            scrollView.setContentOffset(CGPoint(x: centeredOffset(for: index, in: scrollView), y: 0), animated: animated)
        }

        private func commitPendingSelection() {
            guard let index = pendingSelectionIndex else { return }
            pendingSelectionIndex = nil
            lastPreviewIndex = index
            if parent.assets.indices.contains(index) {
                parent.onCommit(parent.assets[index].id)
            }
        }

        private func previewCenteredAsset(in scrollView: UIScrollView) {
            let index = nearestIndex(for: scrollView.contentOffset.x, in: scrollView)
            guard index != lastPreviewIndex, parent.assets.indices.contains(index) else { return }
            lastPreviewIndex = index
            parent.onPreview(parent.assets[index].id)
        }

        private func nearestIndex(for offsetX: CGFloat, in scrollView: UIScrollView) -> Int {
            guard !parent.assets.isEmpty else { return 0 }
            let centerX = offsetX + scrollView.bounds.width / 2
            let sideInset = max(0, (scrollView.bounds.width - parent.itemWidth) / 2)
            let raw = (centerX - sideInset - parent.itemWidth / 2) / (parent.itemWidth + parent.spacing)
            return clampedIndex(Int(round(raw)))
        }

        private func clampedIndex(_ index: Int) -> Int {
            min(max(index, 0), parent.assets.count - 1)
        }

        private func centeredOffset(for index: Int, in scrollView: UIScrollView) -> CGFloat {
            let sideInset = max(0, (scrollView.bounds.width - parent.itemWidth) / 2)
            let itemCenter = sideInset + CGFloat(index) * (parent.itemWidth + parent.spacing) + parent.itemWidth / 2
            let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            return min(max(itemCenter - scrollView.bounds.width / 2, 0), maxOffset)
        }
    }
}

struct TwoFingerCropOverlay: UIViewRepresentable {
    var onTap: () -> Void
    var onBegin: () -> Void
    var onChange: (CGFloat, CGPoint) -> Void
    var onEnd: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onBegin = onBegin
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onBegin: onBegin, onChange: onChange, onEnd: onEnd)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void
        var onBegin: () -> Void
        var onChange: (CGFloat, CGPoint) -> Void
        var onEnd: () -> Void
        private var lastPanTranslation = CGPoint.zero
        private var lastPinchScale: CGFloat = 1

        init(onTap: @escaping () -> Void, onBegin: @escaping () -> Void, onChange: @escaping (CGFloat, CGPoint) -> Void, onEnd: @escaping () -> Void) {
            self.onTap = onTap
            self.onBegin = onBegin
            self.onChange = onChange
            self.onEnd = onEnd
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { onTap() }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastPinchScale = recognizer.scale
                onBegin()
            case .changed:
                let delta = recognizer.scale / lastPinchScale
                lastPinchScale = recognizer.scale
                onChange(delta, .zero)
            case .ended, .cancelled, .failed:
                lastPinchScale = 1
                onEnd()
            default:
                lastPinchScale = 1
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                lastPanTranslation = translation
                onBegin()
            case .changed:
                let delta = CGPoint(x: translation.x - lastPanTranslation.x, y: translation.y - lastPanTranslation.y)
                lastPanTranslation = translation
                onChange(1, delta)
            case .ended, .cancelled, .failed:
                lastPanTranslation = .zero
                onEnd()
            default:
                lastPanTranslation = .zero
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

