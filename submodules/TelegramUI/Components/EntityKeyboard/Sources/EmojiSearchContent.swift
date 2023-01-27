import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData
import TelegramCore
import Postbox
import AnimationCache
import MultiAnimationRenderer
import AccountContext
import AsyncDisplayKit
import ComponentDisplayAdapters
import PagerComponent
import SwiftSignalKit

public final class EmojiSearchContent: ASDisplayNode, EntitySearchContainerNode {
    private struct Params: Equatable {
        var size: CGSize
        var leftInset: CGFloat
        var rightInset: CGFloat
        var bottomInset: CGFloat
        var inputHeight: CGFloat
        var deviceMetrics: DeviceMetrics
    }
    
    private let context: AccountContext
    private var initialFocusId: ItemCollectionId?
    private let hasPremiumForUse: Bool
    private let hasPremiumForInstallation: Bool
    private let parentInputInteraction: EmojiPagerContentComponent.InputInteraction
    private var presentationData: PresentationData
    
    private let keyboardView = ComponentView<Empty>()
    private let panelHostView: PagerExternalTopPanelContainer
    private let inputInteractionHolder: EmojiPagerContentComponent.InputInteractionHolder
    
    private var params: Params?
    
    private var itemGroups: [EmojiPagerContentComponent.ItemGroup] = []
    
    public var onCancel: (() -> Void)?
    
    private let emojiSearchDisposable = MetaDisposable()
    private let emojiSearchResult = Promise<(groups: [EmojiPagerContentComponent.ItemGroup], id: AnyHashable)?>(nil)
    private var emojiSearchResultValue: (groups: [EmojiPagerContentComponent.ItemGroup], id: AnyHashable)?
    
    private var dataDisposable: Disposable?

    public init(
        context: AccountContext,
        items: [FeaturedStickerPackItem],
        initialFocusId: ItemCollectionId?,
        hasPremiumForUse: Bool,
        hasPremiumForInstallation: Bool,
        parentInputInteraction: EmojiPagerContentComponent.InputInteraction
    ) {
        self.context = context
        self.initialFocusId = initialFocusId
        self.hasPremiumForUse = hasPremiumForUse
        self.hasPremiumForInstallation = hasPremiumForInstallation
        self.parentInputInteraction = parentInputInteraction
        
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        self.panelHostView = PagerExternalTopPanelContainer()
        self.inputInteractionHolder = EmojiPagerContentComponent.InputInteractionHolder()
        
        super.init()
        
        for groupItem in items {
            var groupItems: [EmojiPagerContentComponent.Item] = []
            for item in groupItem.topItems {
                var tintMode: EmojiPagerContentComponent.Item.TintMode = .none
                if item.file.isCustomTemplateEmoji {
                    tintMode = .primary
                }
                
                let animationData = EntityKeyboardAnimationData(file: item.file)
                let resultItem = EmojiPagerContentComponent.Item(
                    animationData: animationData,
                    content: .animation(animationData),
                    itemFile: item.file,
                    subgroupId: nil,
                    icon: .none,
                    tintMode: tintMode
                )
                
                groupItems.append(resultItem)
            }
            
            //TODO:localize
            self.itemGroups.append(EmojiPagerContentComponent.ItemGroup(
                supergroupId: AnyHashable(groupItem.info.id),
                groupId: AnyHashable(groupItem.info.id),
                title: groupItem.info.title,
                subtitle: nil,
                actionButtonTitle: "Add \(groupItem.info.title)",
                isFeatured: true,
                isPremiumLocked: !self.hasPremiumForInstallation,
                isEmbedded: false,
                hasClear: false,
                collapsedLineCount: 3,
                displayPremiumBadges: false,
                headerItem: nil,
                items: groupItems
            ))
        }
        
        self.inputInteractionHolder.inputInteraction = EmojiPagerContentComponent.InputInteraction(
            performItemAction: { [weak self] groupId, item, sourceView, sourceRect, sourceLayer, isPreview in
                guard let self else {
                    return
                }
                self.parentInputInteraction.performItemAction(groupId, item, sourceView, sourceRect, sourceLayer, isPreview)
                if self.hasPremiumForUse {
                    self.onCancel?()
                }
            },
            deleteBackwards: {
            },
            openStickerSettings: {
            },
            openFeatured: {
            },
            openSearch: {
            },
            addGroupAction: { [weak self] groupId, isPremiumLocked, _ in
                guard let self else {
                    return
                }
                self.parentInputInteraction.addGroupAction(groupId, isPremiumLocked, false)
                
                if !isPremiumLocked {
                    if self.itemGroups.count == 1 {
                        self.onCancel?()
                    } else {
                        self.itemGroups.removeAll(where: { $0.groupId == groupId })
                        self.update(transition: Transition(animation: .curve(duration: 0.4, curve: .spring)).withUserData(EmojiPagerContentComponent.ContentAnimation(type: .groupRemoved(id: groupId))))
                    }
                }
            },
            clearGroup: { _ in
            },
            pushController: { _ in
            },
            presentController: { _ in
            },
            presentGlobalOverlayController: { _ in
            },
            navigationController: {
                return nil
            },
            requestUpdate: { _ in
            },
            updateSearchQuery: { [weak self] query in
                guard let self else {
                    return
                }
                
                switch query {
                case .none:
                    self.emojiSearchDisposable.set(nil)
                    self.emojiSearchResult.set(.single(nil))
                case let .text(rawQuery, languageCode):
                    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if query.isEmpty {
                        self.emojiSearchDisposable.set(nil)
                        self.emojiSearchResult.set(.single(nil))
                    } else {
                        let context = self.context
                        
                        var signal = context.engine.stickers.searchEmojiKeywords(inputLanguageCode: languageCode, query: query, completeMatch: false)
                        if !languageCode.lowercased().hasPrefix("en") {
                            signal = signal
                            |> mapToSignal { keywords in
                                return .single(keywords)
                                |> then(
                                    context.engine.stickers.searchEmojiKeywords(inputLanguageCode: "en-US", query: query, completeMatch: query.count < 3)
                                    |> map { englishKeywords in
                                        return keywords + englishKeywords
                                    }
                                )
                            }
                        }
                    
                        let hasPremium = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                        |> map { peer -> Bool in
                            guard case let .user(user) = peer else {
                                return false
                            }
                            return user.isPremium
                        }
                        |> distinctUntilChanged
                        
                        let resultSignal = signal
                        |> mapToSignal { keywords -> Signal<[EmojiPagerContentComponent.ItemGroup], NoError> in
                            return combineLatest(
                                context.account.postbox.itemCollectionsView(orderedItemListCollectionIds: [], namespaces: [Namespaces.ItemCollection.CloudEmojiPacks], aroundIndex: nil, count: 10000000),
                                context.engine.stickers.availableReactions(),
                                hasPremium
                            )
                            |> take(1)
                            |> map { view, availableReactions, hasPremium -> [EmojiPagerContentComponent.ItemGroup] in
                                var result: [(String, TelegramMediaFile?, String)] = []
                                
                                var allEmoticons: [String: String] = [:]
                                for keyword in keywords {
                                    for emoticon in keyword.emoticons {
                                        allEmoticons[emoticon] = keyword.keyword
                                    }
                                }
                                
                                for entry in view.entries {
                                    guard let item = entry.item as? StickerPackItem else {
                                        continue
                                    }
                                    for attribute in item.file.attributes {
                                        switch attribute {
                                        case let .CustomEmoji(_, _, alt, _):
                                            if !item.file.isPremiumEmoji || hasPremium {
                                                if !alt.isEmpty, let keyword = allEmoticons[alt] {
                                                    result.append((alt, item.file, keyword))
                                                } else if alt == query {
                                                    result.append((alt, item.file, alt))
                                                }
                                            }
                                        default:
                                            break
                                        }
                                    }
                                }
                                
                                var items: [EmojiPagerContentComponent.Item] = []
                                
                                var existingIds = Set<MediaId>()
                                for item in result {
                                    if let itemFile = item.1 {
                                        if existingIds.contains(itemFile.fileId) {
                                            continue
                                        }
                                        existingIds.insert(itemFile.fileId)
                                        let animationData = EntityKeyboardAnimationData(file: itemFile)
                                        let item = EmojiPagerContentComponent.Item(
                                            animationData: animationData,
                                            content: .animation(animationData),
                                            itemFile: itemFile, subgroupId: nil,
                                            icon: .none,
                                            tintMode: animationData.isTemplate ? .primary : .none
                                        )
                                        items.append(item)
                                    }
                                }
                                
                                return [EmojiPagerContentComponent.ItemGroup(
                                    supergroupId: "search",
                                    groupId: "search",
                                    title: nil,
                                    subtitle: nil,
                                    actionButtonTitle: nil,
                                    isFeatured: false,
                                    isPremiumLocked: false,
                                    isEmbedded: false,
                                    hasClear: false,
                                    collapsedLineCount: nil,
                                    displayPremiumBadges: false,
                                    headerItem: nil,
                                    items: items
                                )]
                            }
                        }
                        
                        self.emojiSearchDisposable.set((resultSignal
                        |> delay(0.15, queue: .mainQueue())
                        |> deliverOnMainQueue).start(next: { [weak self] result in
                            guard let self else {
                                return
                            }
                            self.emojiSearchResult.set(.single((result, AnyHashable(query))))
                        }))
                    }
                case let .category(value):
                    let resultSignal = self.context.engine.stickers.searchEmoji(emojiString: value)
                    |> mapToSignal { files -> Signal<[EmojiPagerContentComponent.ItemGroup], NoError> in
                        var items: [EmojiPagerContentComponent.Item] = []
                        
                        var existingIds = Set<MediaId>()
                        for itemFile in files {
                            if existingIds.contains(itemFile.fileId) {
                                continue
                            }
                            existingIds.insert(itemFile.fileId)
                            let animationData = EntityKeyboardAnimationData(file: itemFile)
                            let item = EmojiPagerContentComponent.Item(
                                animationData: animationData,
                                content: .animation(animationData),
                                itemFile: itemFile, subgroupId: nil,
                                icon: .none,
                                tintMode: animationData.isTemplate ? .primary : .none
                            )
                            items.append(item)
                        }
                        
                        return .single([EmojiPagerContentComponent.ItemGroup(
                            supergroupId: "search",
                            groupId: "search",
                            title: nil,
                            subtitle: nil,
                            actionButtonTitle: nil,
                            isFeatured: false,
                            isPremiumLocked: false,
                            isEmbedded: false,
                            hasClear: false,
                            collapsedLineCount: nil,
                            displayPremiumBadges: false,
                            headerItem: nil,
                            items: items
                        )])
                    }
                        
                    self.emojiSearchDisposable.set((resultSignal
                    |> delay(0.15, queue: .mainQueue())
                    |> deliverOnMainQueue).start(next: { [weak self] result in
                        guard let self else {
                            return
                        }
                        self.emojiSearchResult.set(.single((result, AnyHashable(value))))
                    }))
                }
            },
            updateScrollingToItemGroup: {
            },
            externalCancel: { [weak self] in
                guard let self else {
                    return
                }
                self.onCancel?()
            },
            onScroll: {},
            chatPeerId: nil,
            peekBehavior: nil,
            customLayout: nil,
            externalBackground: nil,
            externalExpansionView: nil,
            useOpaqueTheme: true,
            hideBackground: false
        )
        
        self.dataDisposable = (
            self.emojiSearchResult.get()
            |> deliverOnMainQueue
        ).start(next: { [weak self] emojiSearchResult in
            guard let self else {
                return
            }
            self.emojiSearchResultValue = emojiSearchResult
            self.update(transition: .immediate)
        })
    }
    
    deinit {
        self.emojiSearchDisposable.dispose()
        self.dataDisposable?.dispose()
    }
    
    private func update(transition: Transition) {
        if let params = self.params {
            self.update(size: params.size, leftInset: params.leftInset, rightInset: params.rightInset, bottomInset: params.bottomInset, inputHeight: params.inputHeight, deviceMetrics: params.deviceMetrics, transition: transition)
        }
    }
    
    public func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, inputHeight: CGFloat, deviceMetrics: DeviceMetrics, transition: ContainedViewLayoutTransition) {
        self.update(size: size, leftInset: leftInset, rightInset: rightInset, bottomInset: bottomInset, inputHeight: inputHeight, deviceMetrics: deviceMetrics, transition: Transition(transition))
    }
     
    private func update(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, inputHeight: CGFloat, deviceMetrics: DeviceMetrics, transition: Transition) {
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        
        let params = Params(size: size, leftInset: leftInset, rightInset: rightInset, bottomInset: bottomInset, inputHeight: inputHeight, deviceMetrics: deviceMetrics)
        self.params = params
        
        //TODO:localize
        var emojiContent = EmojiPagerContentComponent(
            id: "emoji",
            context: self.context,
            avatarPeer: nil,
            animationCache: self.context.animationCache,
            animationRenderer: self.context.animationRenderer,
            inputInteractionHolder: self.inputInteractionHolder,
            panelItemGroups: [],
            contentItemGroups: self.itemGroups,
            itemLayoutType: .compact,
            itemContentUniqueId: EmojiPagerContentComponent.ContentId(id: "main", version: 0),
            searchState: .empty(hasResults: false),
            warpContentsOnEdges: false,
            displaySearchWithPlaceholder: "Search Emoji",
            searchCategories: nil,
            searchInitiallyHidden: false,
            searchAlwaysActive: true,
            searchIsPlaceholderOnly: false,
            emptySearchResults: nil,
            enableLongPress: false,
            selectedItems: Set()
        )
        
        if let emojiSearchResult = self.emojiSearchResultValue {
            var emptySearchResults: EmojiPagerContentComponent.EmptySearchResults?
            if !emojiSearchResult.groups.contains(where: { !$0.items.isEmpty }) {
                emptySearchResults = EmojiPagerContentComponent.EmptySearchResults(
                    text: self.presentationData.strings.EmojiSearch_SearchEmojiEmptyResult,
                    iconFile: nil
                )
            }
            emojiContent = emojiContent.withUpdatedItemGroups(panelItemGroups: emojiContent.panelItemGroups, contentItemGroups: emojiSearchResult.groups, itemContentUniqueId: EmojiPagerContentComponent.ContentId(id: emojiSearchResult.id, version: 0), emptySearchResults: emptySearchResults, searchState: .empty(hasResults: true))
        }
        
        let _ = self.keyboardView.update(
            transition: transition.withUserData(EmojiPagerContentComponent.SynchronousLoadBehavior(isDisabled: true)),
            component: AnyComponent(EntityKeyboardComponent(
                theme: self.presentationData.theme,
                strings: self.presentationData.strings,
                isContentInFocus: true,
                containerInsets: UIEdgeInsets(top: 0.0, left: leftInset, bottom: bottomInset, right: rightInset),
                topPanelInsets: UIEdgeInsets(top: 0.0, left: 4.0, bottom: 0.0, right: 4.0),
                emojiContent: emojiContent,
                stickerContent: nil,
                maskContent: nil,
                gifContent: nil,
                hasRecentGifs: false,
                availableGifSearchEmojies: [],
                defaultToEmojiTab: true,
                externalTopPanelContainer: self.panelHostView,
                externalBottomPanelContainer: nil,
                displayTopPanelBackground: .blur,
                topPanelExtensionUpdated: { _, _ in },
                hideInputUpdated: { _, _, _ in },
                hideTopPanelUpdated: { _, _ in
                },
                switchToTextInput: {},
                switchToGifSubject: { _ in },
                reorderItems: { _, _ in },
                makeSearchContainerNode: { _ in return nil },
                contentIdUpdated: { _ in },
                deviceMetrics: deviceMetrics,
                hiddenInputHeight: 0.0,
                inputHeight: 0.0,
                displayBottomPanel: false,
                isExpanded: false,
                clipContentToTopPanel: false,
                hidePanels: true
            )),
            environment: {},
            containerSize: size
        )
        if let keyboardComponentView = self.keyboardView.view as? EntityKeyboardComponent.View {
            if keyboardComponentView.superview == nil {
                self.view.addSubview(keyboardComponentView)
            }
            transition.setFrame(view: keyboardComponentView, frame: CGRect(origin: CGPoint(), size: size))
            
            if let initialFocusId = self.initialFocusId {
                self.initialFocusId = nil
                
                keyboardComponentView.scrollToItemGroup(contentId: "emoji", groupId: AnyHashable(initialFocusId), subgroupId: nil, animated: false)
            }
        }
    }
}