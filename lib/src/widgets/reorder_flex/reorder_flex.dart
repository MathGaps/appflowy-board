import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../utils/log.dart';
import 'drag_state.dart';
import 'drag_target.dart';
import 'drag_target_interceptor.dart';
import 'reorder_mixin.dart';

typedef OnDragStarted = void Function(int index);
typedef OnDragEnded = void Function();
typedef OnReorder = void Function(int fromIndex, int toIndex);

abstract class ReoderFlexDataSource {
  String get identifier;
  UnmodifiableListView<ReoderFlexItem> get items;
}

abstract class ReoderFlexItem {
  String get id;
  ValueNotifier<bool> draggable = ValueNotifier(true);
}

abstract class ReorderDragTargetKeys {
  void insertDragTarget(
    String reorderFlexId,
    String key,
    GlobalObjectKey value,
  );

  GlobalObjectKey? getDragTarget(
    String reorderFlexId,
    String key,
  );

  void removeDragTarget(String reorderFlexId);
}

abstract class ReorderFlexAction {
  void Function(void Function(BuildContext)?)? _scrollToBottom;
  void Function(void Function(BuildContext)?) get scrollToBottom => _scrollToBottom!;

  void Function(int)? _resetDragTargetIndex;
  void Function(int) get resetDragTargetIndex => _resetDragTargetIndex!;
}

class ReorderFlexConfig {
  const ReorderFlexConfig({
    this.useMoveAnimation = true,
    this.direction = Axis.vertical,
    this.dragDirection,
    required this.draggingWidgetOpacity,
  }) : useMovePlaceholder = !useMoveAnimation;

  final bool useMoveAnimation;
  final Axis direction;
  final Axis? dragDirection;
  final double draggingWidgetOpacity;
  final Duration reorderAnimationDuration = const Duration(milliseconds: 200);
  final Duration scrollAnimationDuration = const Duration(milliseconds: 200);
  final bool useMovePlaceholder;
}

class ReorderFlex extends StatefulWidget {
  ReorderFlex({
    super.key,
    required this.scrollController,
    required this.dataSource,
    required this.children,
    required this.config,
    required this.onReorder,
    this.dragStateStorage,
    this.dragTargetKeys,
    this.onDragStarted,
    this.onDragEnded,
    this.interceptor,
    this.reorderFlexAction,
    this.leading,
    this.trailing,
    this.autoScroll = false,
  }) : assert(
          children.every((Widget w) => w.key != null),
          'All child must have a key.',
        );

  final ReoderFlexDataSource dataSource;
  final List<Widget> children;
  final ReorderFlexConfig config;
  final OnReorder onReorder;
  final DraggingStateStorage? dragStateStorage;
  final ReorderDragTargetKeys? dragTargetKeys;
  final ScrollController? scrollController;
  final OnDragStarted? onDragStarted;
  final OnDragEnded? onDragEnded;
  final DragTargetInterceptor? interceptor;
  final ReorderFlexAction? reorderFlexAction;
  final Widget? leading;
  final Widget? trailing;
  final bool autoScroll;

  @override
  State<ReorderFlex> createState() => ReorderFlexState();

  String get reorderFlexId => dataSource.identifier;
}

class ReorderFlexState extends State<ReorderFlex>
    with ReorderFlexMixin, TickerProviderStateMixin<ReorderFlex> {
  late ScrollController _scrollController;
  bool _scrolling = false;
  late DraggingState draggingState;
  late DragTargetAnimation _animation;
  late ReorderFlexNotifier _notifier;
  late ScrollableState _scrollable;
  EdgeDraggingAutoScroller? _autoScroller;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();

    _notifier = ReorderFlexNotifier();
    final flexId = widget.reorderFlexId;
    draggingState =
        widget.dragStateStorage?.readState(flexId) ?? DraggingState(widget.reorderFlexId);
    Log.trace('[DragTarget] init dragState: $draggingState');

    widget.dragStateStorage?.removeState(flexId);

    _animation = DragTargetAnimation(
      reorderAnimationDuration: widget.config.reorderAnimationDuration,
      entranceAnimateStatusChanged: (status) {
        if (status == AnimationStatus.completed) {
          if (!_isDragging || draggingState.nextIndex == -1) return;
          setState(() {});
        }
      },
      vsync: this,
    );

    widget.reorderFlexAction?._scrollToBottom = (fn) {
      scrollToBottom(fn);
    };

    widget.reorderFlexAction?._resetDragTargetIndex = (index) {
      // resetDragTargetIndex(index);
    };

    _scrollController = widget.scrollController ?? ScrollController();
  }

  @override
  void didChangeDependencies() {
    _scrollable = Scrollable.of(context);
    if (_autoScroller?.scrollable != _scrollable && widget.autoScroll) {
      _autoScroller?.stopAutoScroll();
      _autoScroller = EdgeDraggingAutoScroller(
        _scrollable,
        onScrollViewScrolled: () {
          final renderBox =
              draggingState.draggingKey?.currentContext?.findRenderObject() as RenderBox?;
          if (renderBox != null) {
            final offset = renderBox.localToGlobal(Offset.zero);
            final size = draggingState.feedbackSize!;
            if (!size.isEmpty) {
              _autoScroller?.startAutoScrollIfNecessary(
                offset & size,
              );
            }
          }
        },
        velocityScalar: 50,
      );
    }
    super.didChangeDependencies();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = [];

    for (int i = 0; i < widget.children.length; i++) {
      final Widget child = widget.children[i];
      final ReoderFlexItem item = widget.dataSource.items[i];

      final indexKey = GlobalObjectKey(child.key!);
      widget.dragTargetKeys?.insertDragTarget(
        widget.reorderFlexId,
        item.id,
        indexKey,
      );

      children.add(_wrap(child, i, indexKey, item.draggable, widget.reorderFlexId));
    }

    return _wrapContainer(children);
  }

  @override
  void dispose() {
    _animation.dispose();
    // _autoScroller?.dispose();
    super.dispose();
  }

  Widget _wrap(
    Widget child,
    int childIndex,
    GlobalObjectKey indexKey,
    ValueNotifier<bool> isDraggable,
    String reorderFlexId,
  ) {
    return Builder(
      builder: (context) {
        final ReorderDragTarget dragTarget = _buildDragTarget(
          context,
          child,
          childIndex,
          indexKey,
          isDraggable,
        );

        if (_isDragging) {
          if (childIndex == draggingState.nextIndex) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Divider(
                  color: Colors.blue.shade900,
                  height: 20,
                  thickness: 2,
                ),
                dragTarget,
              ],
            );
          }

          if (childIndex == draggingState.dragStartIndex && draggingState.draggingKey == indexKey) {
            return draggingState.draggingWidget!; // Keep original opacity
          }
        }

        return dragTarget;
      },
    );
  }

  // Add this method to handle end-of-list drop
  Widget _wrapContainer(List<Widget> children) {
    Widget container;
    switch (widget.config.direction) {
      case Axis.horizontal:
        container = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.leading != null) widget.leading!,
            ...children,
            if (widget.trailing != null) widget.trailing!,
          ],
        );
        break;
      case Axis.vertical:
        container = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.leading != null) widget.leading!,
            ...children,
            if (widget.trailing != null) widget.trailing!,
            // Add an invisible drop target at the end if dragging
            if (_isDragging)
              DragTarget<FlexDragTargetData>(
                onWillAccept: (data) {
                  if (data != null) {
                    setState(() {
                      draggingState.updateNextIndex(children.length);
                    });
                    return true;
                  }
                  return false;
                },
                builder: (context, candidateData, rejectedData) {
                  return SizedBox(
                    height: 20,
                    child: candidateData.isNotEmpty
                        ? Divider(
                            color: Colors.blue.shade900,
                            thickness: 2,
                          )
                        : null,
                  );
                },
              ),
          ],
        );
        break;
    }
    return container;
  }

  bool handleOnWillAccept(BuildContext context, int dragTargetIndex) {
    final dragIndex = draggingState.dragStartIndex;

    // Allow accepting at any valid position including the end
    final bool willAccept = dragIndex != dragTargetIndex ||
        (dragTargetIndex == widget.children.length && dragIndex != dragTargetIndex - 1);

    if (willAccept) {
      setState(() {
        // Update next index to handle end-of-list case
        final effectiveIndex =
            dragTargetIndex >= widget.children.length ? widget.children.length : dragTargetIndex;
        draggingState.updateNextIndex(effectiveIndex);
      });
    }

    _scrollTo(context);
    return willAccept;
  }

  void _onReordered(int fromIndex, int toIndex) {
    if (fromIndex != toIndex && fromIndex != -1 && toIndex != -1) {
      // Ensure toIndex is valid for end of list drops
      final effectiveToIndex = min(toIndex, widget.children.length);
      widget.onReorder.call(fromIndex, effectiveToIndex);
    }
  }

  ReorderDragTarget _buildDragTarget(
    BuildContext builderContext,
    Widget child,
    int dragTargetIndex,
    GlobalObjectKey indexKey,
    ValueNotifier<bool> isDraggable,
  ) {
    final reorderFlexItem = widget.dataSource.items[dragTargetIndex];
    return ReorderDragTarget<FlexDragTargetData>(
      indexGlobalKey: indexKey,
      isDraggable: isDraggable,
      dragTargetData: FlexDragTargetData(
        draggingIndex: dragTargetIndex,
        reorderFlexId: widget.reorderFlexId,
        reorderFlexItem: reorderFlexItem,
        draggingState: draggingState,
        dragTargetId: reorderFlexItem.id,
        dragTargetIndexKey: indexKey,
      ),
      onDragStarted: (draggingWidget, draggingIndex, size) {
        setState(() {
          _isDragging = true;
          draggingState.draggingKey = indexKey;
          draggingState.startDragging(draggingWidget, draggingIndex, size);
          widget.onDragStarted?.call(draggingIndex);
        });
      },
      onDragMoved: (dragTargetData, offset) {
        draggingState.draggingKey = indexKey;
        final size = dragTargetData.feedbackSize;
        if (size != null) {
          draggingState.feedbackSize = size;
          _autoScroller?.startAutoScrollIfNecessary(
            offset & size,
          );
        }
      },
      onDragEnded: (dragTargetData) {
        if (!mounted) return;

        setState(() {
          _isDragging = false;
          if (dragTargetData.reorderFlexId == widget.reorderFlexId &&
              draggingState.nextIndex != -1) {
            _onReordered(
              draggingState.dragStartIndex,
              draggingState.nextIndex,
            );
          }
          draggingState.endDragging();
          widget.onDragEnded?.call();
        });
      },
      onWillAcceptWithDetails: (FlexDragTargetData dragTargetData) {
        if (_animation.insertController.isAnimating) return false;

        if (dragTargetData.isDragging) {
          if (_interceptDragTarget(dragTargetData, (interceptor) {
            interceptor.onWillAccept(
              context: builderContext,
              reorderFlexState: this,
              dragTargetData: dragTargetData,
              dragTargetId: reorderFlexItem.id,
              dragTargetIndex: dragTargetIndex,
            );
          })) {
            return true;
          } else {
            return handleOnWillAccept(builderContext, dragTargetIndex);
          }
        }
        return false;
      },
      onAccceptWithDetails: (dragTargetData) {
        _interceptDragTarget(
          dragTargetData,
          (interceptor) => interceptor.onAccept(dragTargetData),
        );
      },
      onLeave: (dragTargetData) {
        _interceptDragTarget(
          dragTargetData,
          (interceptor) => interceptor.onLeave(dragTargetData),
        );
      },
      insertAnimationController: _animation.insertController,
      deleteAnimationController: _animation.deleteController,
      draggableTargetBuilder: widget.interceptor?.draggableTargetBuilder,
      useMoveAnimation: widget.config.useMoveAnimation,
      draggingOpacity: widget.config.draggingWidgetOpacity,
      dragDirection: widget.config.dragDirection,
      child: child,
    );
  }

  bool _interceptDragTarget(
    FlexDragTargetData dragTargetData,
    void Function(DragTargetInterceptor) callback,
  ) {
    final interceptor = widget.interceptor;
    if (interceptor != null && interceptor.canHandler(dragTargetData)) {
      callback(interceptor);
      return true;
    }
    return false;
  }

  void scrollToBottom(void Function(BuildContext)? completed) {
    if (_scrolling) {
      completed?.call(context);
      return;
    }

    if (widget.dataSource.items.isNotEmpty) {
      final item = widget.dataSource.items.last;
      final dragTargetKey = widget.dragTargetKeys?.getDragTarget(
        widget.reorderFlexId,
        item.id,
      );
      if (dragTargetKey == null) {
        completed?.call(context);
        return;
      }

      final dragTargetContext = dragTargetKey.currentContext;
      if (dragTargetContext == null || _scrollController.hasClients == false) {
        completed?.call(context);
        return;
      }

      final dragTargetRenderObject = dragTargetContext.findRenderObject();
      if (dragTargetRenderObject != null) {
        _scrolling = true;
        _scrollController.position
            .ensureVisible(
          dragTargetRenderObject,
          alignment: 0.5,
          duration: const Duration(milliseconds: 120),
        )
            .then((value) {
          setState(() {
            _scrolling = false;
            completed?.call(context);
          });
        });
      } else {
        completed?.call(context);
      }
    }
  }

// Scrolls to a target context if that context is not on the screen.
  void _scrollTo(BuildContext context) {
    if (_scrolling) return;
    final RenderObject contextObject = context.findRenderObject()!;
    final RenderAbstractViewport viewport = RenderAbstractViewport.of(contextObject);
    // If and only if the current scroll offset falls in-between the offsets
    // necessary to reveal the selected context at the top or bottom of the
    // screen, then it is already on-screen.
    final double margin = widget.config.direction == Axis.horizontal
        ? draggingState.dropAreaSize.width
        : draggingState.dropAreaSize.height / 2.0;
    if (_scrollController.hasClients) {
      final double scrollOffset = _scrollController.offset;
      final double topOffset = max(
        _scrollController.position.minScrollExtent,
        viewport.getOffsetToReveal(contextObject, 0.0).offset - margin,
      );
      final double bottomOffset = min(
        _scrollController.position.maxScrollExtent,
        viewport.getOffsetToReveal(contextObject, 1.0).offset + margin,
      );
      final bool onScreen = scrollOffset <= topOffset && scrollOffset >= bottomOffset;

      // If the context is off screen, then we request a scroll to make it visible.
      if (!onScreen) {
        _scrolling = true;
        _scrollController.position
            .animateTo(
          scrollOffset < bottomOffset ? bottomOffset : topOffset,
          duration: widget.config.scrollAnimationDuration,
          curve: Curves.easeInOut,
        )
            .then((void value) {
          setState(() => _scrolling = false);
        });
      }
    }
  }
}
