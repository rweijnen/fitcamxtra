import SwiftUI

struct SDCardView: View {
    @Environment(AppState.self) private var state

    @State private var filter: FileFilter = .all
    @State private var selecting = false
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

                    if let failure {
                        Text(failure)
                            .font(Typo.mono(11))
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
            if state.connection.isConnected && library.files.isEmpty {
                await library.loadFiles()
            }
        }
        .refreshable { await library.loadFiles() }
        .fullScreenCover(item: $openFile) { file in
            FileDetailView(file: file)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SD card")
                .font(Typo.sans(30, .semibold))
                .tracking(-0.9)
                .foregroundStyle(Palette.ink)

            Spacer()

            if !library.files.isEmpty {
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    selected.removeAll()
                }
                .font(Typo.sans(13.5, .semibold))
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
                            .font(Typo.mono(11))
                            .foregroundStyle(Palette.inkQuaternary)
                        Spacer()
                        Text(byteLabel(total))
                            .font(Typo.mono(11))
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
                        if let used = state.sdCardPercentUsed {
                            legend("CARD \(used)% USED", color: Palette.inkQuaternary)
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
            .font(Typo.mono(10.5))
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
                        .font(Typo.sans(13))
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
                .font(Typo.mono(11.5))
                .foregroundStyle(Palette.inkQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Grid

    private func dayGroup(_ day: Date?, files: [MediaFile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayLabel(day))
                    .font(Typo.sans(13, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(files.count) item\(files.count == 1 ? "" : "s") - \(byteLabel(files.reduce(0) { $0 + $1.byteCount }))")
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.inkQuaternary)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(files) { file in
                    FileTile(
                        file: file,
                        downloader: state.downloader,
                        isSelected: selected.contains(file.id),
                        isSelecting: selecting
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

    // MARK: - Selection

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await saveSelected() }
            } label: {
                Text(busy ?? "Save \(selected.count) to Photos")
                    .font(Typo.sans(14, .semibold))
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
                Task { await deleteSelected() }
            } label: {
                Text("Delete")
                    .font(Typo.sans(14, .semibold))
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
        .padding(.bottom, 88)
    }

    private func saveSelected() async {
        let files = library.files.filter { selected.contains($0.id) }
        failure = nil
        for (index, file) in files.enumerated() {
            busy = "Saving \(index + 1) of \(files.count)"
            do {
                try await state.downloader.saveToPhotos(file)
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
        for (index, file) in files.enumerated() {
            busy = "Deleting \(index + 1) of \(files.count)"
            do {
                try await state.downloader.delete(file, client: state.cameraClient())
            } catch {
                failure = error.localizedDescription
                break
            }
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
                    Spacer()
                    if file.kind == .photo {
                        Text("JPG")
                            .font(Typo.mono(9))
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
                        .font(Typo.mono(9.5, .semibold))
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
            thumbnail = await downloader.thumbnail(for: file)
        }
    }
}
