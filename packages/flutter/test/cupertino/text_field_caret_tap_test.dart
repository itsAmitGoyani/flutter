// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../widgets/clipboard_utils.dart';
import '../widgets/editable_text_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final mockClipboard = MockClipboard();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    mockClipboard.handleMethodCall,
  );

  // A finger tap is rarely still. On iOS the collapsed caret handle takes a
  // move of over two logical pixels as the start of a caret drag, so a tap on
  // the caret with a small move is a drag that ends as a clean tap.
  Future<void> tapWithSmallMove(WidgetTester tester, Offset position) async {
    final TestGesture gesture = await tester.startGesture(position);
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveBy(const Offset(3.0, 0.0));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  // The affinity of a caret at the end of a line is upstream, so only the
  // offset is compared.
  void expectCaretAt(TextEditingController controller, int offset) {
    expect(controller.selection.isCollapsed, isTrue);
    expect(controller.selection.extentOffset, offset);
  }

  // Lets the field use the system context menu and counts its platform calls.
  // The clipboard mock keeps the other calls.
  SystemMenuCalls mockSystemContextMenu(WidgetTester tester) {
    tester.platformDispatcher.supportsShowingSystemContextMenu = true;
    addTearDown(() {
      tester.platformDispatcher.resetSupportsShowingSystemContextMenu();
      tester.view.reset();
    });
    final calls = SystemMenuCalls();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'ContextMenu.showSystemContextMenu':
          calls.shows += 1;
          return null;
        case 'ContextMenu.hideSystemContextMenu':
          calls.hides += 1;
          return null;
      }
      return mockClipboard.handleMethodCall(call);
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        mockClipboard.handleMethodCall,
      );
    });
    return calls;
  }

  // Pumps a Cupertino field that can use the system context menu, or the same
  // app without the field when [showField] is false.
  Future<void> pumpSystemMenuField(
    WidgetTester tester,
    TextEditingController controller, {
    bool showField = true,
  }) {
    return tester.pumpWidget(
      // Not wrapped with the global View, so the platformDispatcher change is
      // read.
      wrapWithView: false,
      View(
        view: tester.view,
        child: CupertinoApp(
          home: Center(
            child: showField ? CupertinoTextField(controller: controller) : const SizedBox(),
          ),
        ),
      ),
    );
  }

  // Delivers the platform's dismiss message, as UIKit sends it when a touch
  // begins outside of the menu.
  Future<void> sendSystemDismiss() async {
    final ByteData? message = const JSONMessageCodec().encodeMessage(<String, dynamic>{
      'method': 'ContextMenu.onDismissSystemContextMenu',
    });
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/platform',
      message,
      (ByteData? data) {},
    );
  }

  // Focuses the field with a tap at the end of its text and returns the global
  // position of the caret.
  Future<Offset> focusAtEnd(WidgetTester tester, TextEditingController controller) async {
    final Offset caret = textOffsetToPosition(tester, controller.text.length);
    await tester.tapAt(caret);
    // Longer than the double tap window, so the next tap is a new series.
    await tester.pump(const Duration(milliseconds: 500));
    expectCaretAt(controller, controller.text.length);
    return caret;
  }

  group('a clean tap on the caret that began as a caret drag', () {
    setUp(() {
      mockClipboard.clipboardData = <String, dynamic>{'text': 'clip'};
    });

    testWidgets(
      'closes the visible toolbar and does not reopen it',
      (WidgetTester tester) async {
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          CupertinoApp(
            home: Center(child: CupertinoTextField(controller: controller)),
          ),
        );
        final Offset caret = await focusAtEnd(tester, controller);
        expect(find.byType(CupertinoTextSelectionToolbar), findsNothing);

        // A still tap on the caret toggles the toolbar on.
        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoTextSelectionToolbar), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 500));

        // A tap that began as a drag hid the toolbar through the magnifier at the
        // drag start. The clean tap at its end must not toggle it back on.
        await tapWithSmallMove(tester, caret);
        expect(find.byType(CupertinoTextSelectionToolbar), findsNothing);
        expectCaretAt(controller, 5);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'closes the visible system context menu and does not reopen it',
      (WidgetTester tester) async {
        final SystemMenuCalls calls = mockSystemContextMenu(tester);
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await pumpSystemMenuField(tester, controller);
        final Offset caret = await focusAtEnd(tester, controller);
        expect(find.byType(SystemContextMenu), findsNothing);
        expect(calls.shows, 0);

        // A still tap on the caret shows the system context menu.
        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(find.byType(SystemContextMenu), findsOneWidget);
        expect(calls.shows, 1);
        await tester.pump(const Duration(milliseconds: 500));

        // One tap, one hide, and no second show.
        await tapWithSmallMove(tester, caret);
        expect(find.byType(SystemContextMenu), findsNothing);
        expect(calls.hides, 1);
        expect(calls.shows, 1);
        expectCaretAt(controller, 5);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'opens the toolbar when none was visible',
      (WidgetTester tester) async {
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          CupertinoApp(
            home: Center(child: CupertinoTextField(controller: controller)),
          ),
        );
        final Offset caret = await focusAtEnd(tester, controller);
        expect(find.byType(CupertinoTextSelectionToolbar), findsNothing);

        // The forwarded clean tap toggles the toolbar on, as a still tap does.
        await tapWithSmallMove(tester, caret);
        expect(find.byType(CupertinoTextSelectionToolbar), findsOneWidget);
        expectCaretAt(controller, 5);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('a still tap on the caret while the platform hides the system context menu', () {
    setUp(() {
      mockClipboard.clipboardData = <String, dynamic>{'text': 'clip'};
    });

    // Measured on iOS 26: the dismiss message reaches the framework about
    // 15 ms after the pointer down of the touch that dismissed the menu,
    // sometimes a few ms before it, and always before the tap up.
    testWidgets(
      'closes the menu once when the dismiss arrives after the pointer down',
      (WidgetTester tester) async {
        final SystemMenuCalls calls = mockSystemContextMenu(tester);
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await pumpSystemMenuField(tester, controller);
        final Offset caret = await focusAtEnd(tester, controller);

        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(find.byType(SystemContextMenu), findsOneWidget);
        expect(calls.shows, 1);
        await tester.pump(const Duration(milliseconds: 500));

        final TestGesture gesture = await tester.startGesture(caret);
        await tester.pump(const Duration(milliseconds: 15));
        await sendSystemDismiss();
        await tester.pump();
        expect(find.byType(SystemContextMenu), findsNothing);
        await tester.pump(const Duration(milliseconds: 60));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.byType(SystemContextMenu), findsNothing);
        expect(calls.shows, 1);
        expectCaretAt(controller, 5);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'closes the menu once when the dismiss arrives before the pointer down',
      (WidgetTester tester) async {
        final SystemMenuCalls calls = mockSystemContextMenu(tester);
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await pumpSystemMenuField(tester, controller);
        final Offset caret = await focusAtEnd(tester, controller);

        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(calls.shows, 1);
        await tester.pump(const Duration(milliseconds: 500));

        await sendSystemDismiss();
        await tester.pump(const Duration(milliseconds: 8));
        final TestGesture gesture = await tester.startGesture(caret);
        await tester.pump(const Duration(milliseconds: 60));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.byType(SystemContextMenu), findsNothing);
        expect(calls.shows, 1);
        expectCaretAt(controller, 5);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'a tap long after a system hide shows the menu again',
      (WidgetTester tester) async {
        final SystemMenuCalls calls = mockSystemContextMenu(tester);
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await pumpSystemMenuField(tester, controller);
        final Offset caret = await focusAtEnd(tester, controller);

        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(calls.shows, 1);
        await tester.pump(const Duration(milliseconds: 500));

        // The platform hides the menu with no tap on the field, for example for
        // a tap on a menu item. A tap after the longest duration of a tap is a
        // new gesture and shows the menu.
        await sendSystemDismiss();
        await tester.pump();
        expect(find.byType(SystemContextMenu), findsNothing);
        await tester.pump(const Duration(seconds: 1));
        await tester.tapAt(caret);
        await tester.pumpAndSettle();

        expect(find.byType(SystemContextMenu), findsOneWidget);
        expect(calls.shows, 2);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'a tap that moves the caret ends the hide, so a caret tap soon after shows the menu',
      (WidgetTester tester) async {
        final SystemMenuCalls calls = mockSystemContextMenu(tester);
        final controller = TextEditingController(text: 'hello world');
        addTearDown(controller.dispose);
        await pumpSystemMenuField(tester, controller);
        final Offset caret = await focusAtEnd(tester, controller);

        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(calls.shows, 1);
        await tester.pump(const Duration(milliseconds: 500));

        // A tap at the start of the text dismisses the menu and moves the
        // caret. The caret move hides the toolbar from the framework side,
        // which ends the mark of the system hide.
        final Offset start = textOffsetToPosition(tester, 0);
        final TestGesture gesture = await tester.startGesture(start);
        await tester.pump(const Duration(milliseconds: 15));
        await sendSystemDismiss();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        await gesture.up();
        await tester.pump();
        expectCaretAt(controller, 0);
        expect(calls.shows, 1);

        // Past the double tap window, but still within kLongPressTimeout of
        // the hide: a new tap on the caret shows the menu, as in a native
        // field.
        await tester.pump(const Duration(milliseconds: 320));
        await tester.tapAt(start);
        await tester.pumpAndSettle();
        expect(find.byType(SystemContextMenu), findsOneWidget);
        expect(calls.shows, 2);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'a paste from the menu ends the hide, so the next toggle shows the menu',
      (WidgetTester tester) async {
        final SystemMenuCalls calls = mockSystemContextMenu(tester);
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await pumpSystemMenuField(tester, controller);
        final Offset caret = await focusAtEnd(tester, controller);

        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(calls.shows, 1);
        await tester.pump(const Duration(milliseconds: 500));

        // The platform hides the menu for the tap on its Paste item, then the
        // paste runs and hides the toolbar from the framework side.
        await sendSystemDismiss();
        await tester.pump();
        final EditableTextState state = tester.state<EditableTextState>(find.byType(EditableText));
        await state.pasteText(SelectionChangedCause.toolbar);
        await tester.pump();
        expect(controller.text, 'helloclip');

        // Within kLongPressTimeout of the hide, a toggle shows the menu: the
        // paste ended the mark, so the hide does not count for this toggle.
        await tester.pump(const Duration(milliseconds: 200));
        state.toggleToolbar(false);
        await tester.pumpAndSettle();
        expect(find.byType(SystemContextMenu), findsOneWidget);
        expect(calls.shows, 2);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'a system hide one frame after the field is disposed does nothing',
      (WidgetTester tester) async {
        final SystemMenuCalls calls = mockSystemContextMenu(tester);
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await pumpSystemMenuField(tester, controller);
        final Offset caret = await focusAtEnd(tester, controller);

        await tester.tapAt(caret);
        await tester.pumpAndSettle();
        expect(calls.shows, 1);
        await tester.pump(const Duration(milliseconds: 500));

        // The field goes away. The overlay entry of the menu is removed one
        // frame later, so in this frame the SystemContextMenu still reports
        // to the disposed state.
        await pumpSystemMenuField(tester, controller, showField: false);
        expect(find.byType(CupertinoTextField), findsNothing);
        expect(find.byType(SystemContextMenu), findsOneWidget);
        await sendSystemDismiss();
        await tester.pump();
        expect(find.byType(SystemContextMenu), findsNothing);
        // The test binding fails this test if a timer is still pending here.
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  testWidgets(
    'a clean tap on a selection handle that began as a drag still collapses the selection',
    (WidgetTester tester) async {
      mockClipboard.clipboardData = <String, dynamic>{'text': 'clip'};
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        CupertinoApp(
          home: Center(child: CupertinoTextField(controller: controller)),
        ),
      );

      // Double tap selects the first word and shows the toolbar with handles.
      final Offset inWord = textOffsetToPosition(tester, 2);
      await tester.tapAt(inWord);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(inWord);
      await tester.pumpAndSettle();
      expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
      expect(find.byType(CupertinoTextSelectionToolbar), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));

      // The handles are the two painted Cupertino handle visuals, start first.
      // The end handle's ball hangs below the end of the selection.
      final Finder handleVisuals = find.byWidgetPredicate(
        (Widget widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() == '_CupertinoTextSelectionHandlePainter',
      );
      expect(handleVisuals, findsNWidgets(2));
      final Rect ball = tester.getRect(handleVisuals.last);
      await tapWithSmallMove(tester, Offset(ball.center.dx, ball.bottom - 6.0));

      // The forwarded tap collapses the selection at the endpoint, which hides
      // the toolbar; nothing reopens it.
      expect(controller.selection.isCollapsed, isTrue);
      expect(controller.selection.extentOffset, 5);
      expect(find.byType(CupertinoTextSelectionToolbar), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

/// The platform channel calls of the system context menu, counted by a mock.
class SystemMenuCalls {
  int shows = 0;
  int hides = 0;
}
