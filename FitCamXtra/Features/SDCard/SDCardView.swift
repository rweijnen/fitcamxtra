import SwiftUI

struct SDCardView: View {
    @Environment(AppState.self) private var state

    @State private var filter: FileFilter = .all
    @State private var selecting = false
    @State private var showBulkDeleteConfirm = false
    @State private var selected: Set<String> = []
    @State private var openFile: MediaFile?
    @State private var busy: String?
    @State private var failure: String?

    private var library: MediaLibrary { state.library }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    storage
                    filterChips

                    if library.isLoadingFiles && library.files.isEmpty {
                        loading
                    } else if let problem = library.lastError, library.files.isEmpty {
                        // A failed read is not an empty card, and saying it is
                        // tells someone who has just had a crash that their
                        // camera locked nothing.
                        readFailed(problem)
                    } else if library.files.isEmpty {
                        EmptyStateCard(
                            eyebrow: "Card",
                            headline: state.connection.isConnected
                                ? "Nothing on the card yet"
                                : "Connect to browse the card",
                            detail: state.connection.isConnected
                                ? "If the camera has recorded but nothing appears, the diagnostics log holds the raw listing the camera returned."
                                : "The file list comes from the camera, so the app has to be connected to read it."
                        )
                    } else {
                        ForEach(library.filesByDay(filter: filter), id: \.day) { group in
                            dayGroup(group.day, files: group.files)
                        }
                    }

                    if state.downloader.thumbnailsUnavailable, !library.files.isEmpty {
                        // 80 identical hazard-striped tiles with no
                        // explanation reads as a broken app rather than as a
                        // camera that will not send previews.
                        Text("This camera will not send previews, so clips are listed by time.")
                            .font(Typo.mono(.micro))
                            .foregroundStyle(Palette.inkQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let failure {
                        Text(failure)
                            .font(Typo.mono(.detail))
                            .foregroundStyle(Palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, Metrics.scrollBottom)
            }

            if selecting && !selected.isEmpty {
                actionBar
            }
        }
        .background(Palette.bg)
        .task(id: state.connection.camera?.host) {
            // A remembered listing shows at once; the camera still gets asked,
            // because what is on the card may have moved on without us.
            if state.connection.isConnected && (library.files.isEmpty || library.isShowingCachedListing) {
                await library.loadFiles()
            }
        }
        .refreshable { await library.loadFiles() }
        .fullScreenCover(item: $openFile) { file in
            FileDetailView(file: file)
        }
    }

    /// Says the read failed, and offers the only useful next step.
    private func readFailed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Card", color: Palette.destructiveText)

            Text("Could not read the card")
                .font(Typo.sans(.cardTitle, .semibold))
                .foregroundStyle(Palette.ink)

            Text(reason)
                .font(Typo.mono(.detail))
                .foregroundStyle(Palette.destructiveText)
                .fixedSize(horizontal: false, vertical: true)

            Text("The clips are still on the camera. This is the app failing to read the listing, not an empty card.")
                .font(Typo.sans(.detail))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await library.loadFiles() }
            } label: {
                Text("Try again")
                    .font(Typo.sans(.body, .semibold))
                    .foregroundStyle(Palette.accentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                            .fill(Palette.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(border: Palette.destructiveText.opacity(0.4))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SD card")
                .font(Typo.sans(.screenTitle, .semibold))
                .tracking(-0.9)
                .foregroundStyle(Palette.ink)

            Spacer()

            if selecting {
                // Freeing space meant tapping every tile. On an 83-clip card
                // that is 83 taps to do the one thing the screen is for.
                Button(selected.count == visibleFiles.count ? "None" : "All") {
                    selected = selected.count == visibleFiles.count
                        ? []
                        : Set(visibleFiles.map(\.id))
                }
                .font(Typo.sans(.body, .semibold))
                .foregroundStyle(Palette.accent)
                .frame(minHeight: 44)
            }

            if library.isShowingCachedListing {
                Text(library.listingFetchedAt.map { "From \($0.formatted(date: .omitted, time: .shortened))" }
                     ?? "From last visit")
                    .font(Typo.mono(.micro))
                    .foregroundStyle(Palette.inkQuaternary)
            }

            if !library.files.isEmpty {
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    selected.removeAll()
                }
                .font(Typo.sans(.body, .semibold))
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(.top, Metrics.headerTop)
    }

    private var storage: some View {
        Group {
            if !library.files.isEmpty {
                let total = library.totalBytes
                let locked = library.lockedBytes
                let lockedFraction = total > 0 ? Double(locked) / Double(total) : 0

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(library.files.filter { $0.kind == .video }.count) CLIPS - \(library.files.filter { $0.kind == .photo }.count) PHOTOS")
                            .font(Typo.mono(.detail))
                            .foregroundStyle(Palette.inkQuaternary)
                        Spacer()
                        Text(byteLabel(total))
                            .font(Typo.mono(.detail))
                            .foregroundStyle(Palette.inkQuaternary)
                    }

                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Palette.accent)
                                .frame(width: geometry.size.width * lockedFraction)
                            Rectangle().fill(Palette.ink.opacity(0.55))
                        }
                    }
                    .frame(height: 5)
                    .clipShape(Capsule())

                    HStack(spacing: 14) {
                        legend("LOCKED \(byteLabel(locked))", color: Palette.accentText)
                        legend("LOOP \(byteLabel(total - locked))", color: Palette.inkQuaternary)
                        Spacer()
                        if state.sdCardLooksUnhealthy {
                            legend("CARD NOT READY", color: Palette.destructiveText)
                        }
                    }
                }
                .padding(15)
                .cardSurface()
            }
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typo.mono(.micro))
            .foregroundStyle(color)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(FileFilter.allCases) { option in
                let active = filter == option
                Button {
                    filter = option
                } label: {
                    Text(option.rawValue)
                        .font(Typo.sans(.label))
                        .foregroundStyle(active ? Palette.accentInk : Palette.inkSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                                .fill(active ? Palette.accent : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                                .strokeBorder(active ? Color.clear : Palette.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Palette.accent)
            Text("Reading the card")
                .font(Typo.mono(.detail))
                .foregroundStyle(Palette.inkQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Grid

    private func selectDay(_ files: [MediaFile]) {
        let ids = Set(files.map(\.id))
        if ids.isSubset(of: selected) {
            selected.subtract(ids)
        } else {
            selected.formUnion(ids)
        }
    }

    private func dayGroup(_ day: Date?, files: [MediaFile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayLabel(day))
                    .font(Typo.sans(.label, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()

                if selecting {
                    // A day is the unit people actually think in when they
                    // are clearing space.
                    Button("Select day") { selectDay(files) }
                        .font(Typo.sans(.detail, .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: 44)
                } else {
                    Text("\(files.count) item\(files.count == 1 ? "" : "s") - \(byteLabel(files.reduce(0) { $0 + $1.byteCount }))")
                        .font(Typo.mono(.detail))
                        .foregroundStyle(Palette.inkQuaternary)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(files) { file in
                    FileTile(
                        file: file,
                        downloader: state.downloader,
                        isSelected: selected.contains(file.id),
                        isSelecting: selecting,
                        isSaved: state.hasBeenSaved(file)
                    )
                    .onTapGesture {
                        if selecting {
                            if selected.contains(file.id) {
                                selected.remove(file.id)
                            } else {
                                selected.insert(file.id)
                            }
                        } else {
                            openFile = file
                        }
                    }
                }
            }
        }
    }

    /// What the current filter is showing, which is what "All" should mean.
    private var visibleFiles: [MediaFile] {
        library.filesByDay(filter: filter).flatMap(\.files)
    }

    private var selectedLockedCount: Int {
        library.files.filter { selected.contains($0.id) && $0.isLocked }.count
    }

    // MARK: - Selection

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await saveSelected() }
            } label: {
                Text(busy ?? "Save \(selected.count) to Photos")
                    .font(Typo.sans(.body, .semibold))
                    .foregroundStyle(Palette.accentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                            .fill(Palette.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(busy != nil)

            Button {
                showBulkDeleteConfirm = true
            } label: {
                Text("Delete")
                    .font(Typo.sans(.body, .semibold))
                    .foregroundStyle(Palette.destructiveText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                            .fill(Palette.destructiveBg)
                    )
            }
            .buttonStyle(.plain)
            .disabled(busy != nil)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                .strokeBorder(Palette.glassBorder, lineWidth: 1)
        )
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 12)
        // The single-file path has always confirmed, and the camera settings
        // confirm; only the one that erases many clips at once did not, and
        // it sits next to Save with no undo behind it.
        .confirmationDialog(
            selectedLockedCount > 0
                ? "Delete \(selected.count) clips, including \(selectedLockedCount) locked?"
                : "Delete \(selected.count) clips?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selected.count)", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selectedLockedCount > 0
                 ? "Locked clips are the ones the button or the G-sensor protected. This erases them from the card, and nothing on the phone keeps a copy unless it was saved to Photos."
                 : "This erases them from the card. Nothing on the phone keeps a copy unless it was saved to Photos.")
        }
    }

    private func saveSelected() async {
        let files = library.files.filter { selected.contains($0.id) }
        failure = nil
        for (index, file) in files.enumerated() {
            busy = "Saving \(index + 1) of \(files.count)"
            do {
                try await state.downloader.saveToPhotos(file) { update in
                    let share = update.fraction.map { " — \(Int($0 * 100))%" } ?? ""
                    busy = "Saving \(index + 1) of \(files.count)\(share)"
                }
                state.markSaved(file)
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        busy = nil
        selected.removeAll()
        selecting = false
    }

    private func deleteSelected() async {
        let files = library.files.filter { selected.contains($0.id) }
        failure = nil
        var deleted = 0
        var firstFailure: String?

        for (index, file) in files.enumerated() {
            busy = "Deleting \(index + 1) of \(files.count)"
            do {
                try await state.downloader.delete(file, client: state.cameraClient())
                deleted += 1
            } catch {
                // Carry on rather than stopping at the first one: the rest
                // were asked for too, and a half-done selection with one red
                // line explains nothing about which clips are still there.
                if firstFailure == nil { firstFailure = error.localizedDescription }
            }
        }

        if let firstFailure {
            failure = deleted == 0
                ? "Nothing was deleted: \(firstFailure)"
                : "Deleted \(deleted) of \(files.count). The rest failed: \(firstFailure)"
        }
        busy = nil
        selected.removeAll()
        selecting = false
        await library.loadFiles()
    }

    // MARK: - Formatting

    private func dayLabel(_ day: Date?) -> String {
        guard let day else { return "Date not reported" }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func byteLabel(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

struct FileTile: View {
    let file: MediaFile
    let downloader: MediaDownloader
    let isSelected: Bool
    let isSelecting: Bool
    /// Already copied to Photos. Without this the only way to know was to
    /// save it again and wait out another 80 MB.
    let isSaved: Bool

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    CameraPlaceholder()
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            if isSelected {
                Palette.accent.opacity(0.28)
            }

            VStack {
                HStack(alignment: .top) {
                    if file.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    if isSaved {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.accentInk)
                            .padding(4)
                            .background(Circle().fill(Palette.accent))
                            .accessibilityLabel("Already saved to Photos")
                    }
                    Spacer()
                    if file.kind == .photo {
                        Text("JPG")
                            .font(Typo.mono(.micro))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.45)))
                    } else if isSelected {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Palette.accentInk)
                            )
                    }
                }
                Spacer()
                HStack {
                    Text(file.timeLabel)
                        .font(Typo.mono(.micro, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.5)))
                    Spacer()
                }
            }
            .padding(5)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent : Color.clear, lineWidth: 2)
        )
        .task {
            // Whatever is already on disk, with no request at all.
            if let cached = downloader.cachedThumbnail(for: file) {
                thumbnail = cached
                return
            }
            thumbnail = await downloader.thumbnail(for: file)
        }
    }
}
