import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:saber/components/home/grid_folders.dart';
import 'package:saber/components/home/masonry_files.dart';
import 'package:saber/components/home/new_folder_button.dart';
import 'package:saber/components/home/no_files.dart';
import 'package:saber/components/home/syncing_button.dart';
import 'package:saber/components/theming/adaptive_icon.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/routes.dart';
import 'package:saber/i18n/strings.g.dart';

class BrowsePage extends StatefulWidget {
  const BrowsePage({
    super.key,
    String? path,
  }) : initialPath = path;

  final String? initialPath;

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}
class _BrowsePageState extends State<BrowsePage> {
  DirectoryChildren? children;

  final List<String?> pathHistory = [];
  String? path;

  @override
  void initState() {
    path = widget.initialPath;

    findChildrenOfPath();
    fileWriteSubscription = FileManager.fileWriteStream.stream.listen(fileWriteListener);

    super.initState();
  }

  StreamSubscription? fileWriteSubscription;
  void fileWriteListener(FileOperation event) {
    if (!event.filePath.startsWith(path ?? '/')) return;
    findChildrenOfPath(fromFileListener: true);
  }

  Future findChildrenOfPath({bool fromFileListener = false}) async {
    if (!mounted) return;

    if (fromFileListener) {
      // don't refresh if we're not on the home page
      final location = GoRouter.of(context).location;
      if (!location.startsWith(RoutePaths.prefixOfHome)) return;
    }

    children = await FileManager.getChildrenOfDirectory(path ?? '/');

    if (mounted) setState(() {});
  }

  void onDirectoryTap(String folder) {
    if (folder == '..') {
      path = pathHistory.isEmpty ? null : pathHistory.removeLast();
    } else {
      pathHistory.add(path);
      path = "${path ?? ''}/$folder";
    }
    context.go(HomeRoutes.browseFilePath(path ?? '/'));
    findChildrenOfPath();
  }

  Future<void> createFolder(String folderName) async {
    final folderPath = '${path ?? ''}/$folderName';
    await FileManager.createFolder(folderPath);
    findChildrenOfPath();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final platform = Theme.of(context).platform;
    final cupertino = platform == TargetPlatform.iOS
        || platform == TargetPlatform.macOS;

    String title = t.home.titles.browse;
    if (path?.isNotEmpty ?? false) {
      title += ': $path';
    }

    final crossAxisCount = MediaQuery.of(context).size.width ~/ 300 + 1;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => Future.wait([
          findChildrenOfPath(),
          Future.delayed(const Duration(milliseconds: 500)),
        ]),
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              collapsedHeight: kToolbarHeight,
              expandedHeight: 200,
              pinned: true,
              flexibleSpace: FlexibleSpaceBar(
                title: Text(
                  title,
                  style: TextStyle(color: colorScheme.onBackground),
                ),
                centerTitle: cupertino,
                titlePadding: EdgeInsetsDirectional.only(
                  start: cupertino ? 0 : 16,
                  bottom: 16
                ),
              ),
              actions: [
                NewFolderButton(
                  createFolder: createFolder,
                  doesFolderExist: (String folderName) {
                    return children?.directories.contains(folderName) ?? false;
                  },
                ),
                const SyncingButton(),
              ],
            ),
            GridFolders(
              isAtRoot: path?.isEmpty ?? true,
              crossAxisCount: crossAxisCount,
              onTap: onDirectoryTap,
              folders: [
                for (String directoryPath in children?.directories ?? const [])
                  directoryPath,
              ],
            ),

            if (children == null) ...[
              // loading
            ] else if (children!.isEmpty) ...[
              const SliverSafeArea(
                sliver: SliverToBoxAdapter(
                  child: NoFiles(),
                ),
              ),
            ] else ...[
              SliverSafeArea(
                sliver: MasonryFiles(
                  crossAxisCount: crossAxisCount,
                  files: [
                    for (String filePath in children?.files ?? const [])
                      "${path ?? ""}/$filePath",
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        shape: cupertino ? const CircleBorder() : null,
        onPressed: () {
          context.push(RoutePaths.edit);
        },
        tooltip: t.home.tooltips.newNote,
        child: const AdaptiveIcon(
          icon: Icons.add,
          cupertinoIcon: CupertinoIcons.add,
        ),
      ),
    );
  }

  @override
  void dispose() {
    fileWriteSubscription?.cancel();
    super.dispose();
  }
}
