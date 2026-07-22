import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/series_item.dart';
import '../../../data/models/vod_item.dart';
import '../../../state/series_providers.dart'
    show allSeriesProvider, adultSeriesIdsProvider, adultSeriesCategoryIdsProvider;
import '../../../state/vod_providers.dart'
    show allVodProvider, adultVodIdsProvider, adultVodCategoryIdsProvider;
import '../../common/grid_metrics.dart';
import '../../common/tv_focusable.dart';

/// Combined "recently added" screen split into two tabs: SERIES and MOVIES.
/// Each tab shows its own content, always sorted newest-added first.
class NewScreen extends ConsumerStatefulWidget {
  const NewScreen({super.key});

  @override
  ConsumerState<NewScreen> createState() => _NewScreenState();
}

class _NewScreenState extends ConsumerState<NewScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('New'),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: AppColors.red,
          labelColor: Colors.white,
          unselectedLabelColor: AppColors.textSecondary,
          labelStyle: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5),
          tabs: const [
            Tab(text: 'SERIES'),
            Tab(text: 'MOVIES'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _NewSeriesTab(),
          _NewMoviesTab(),
        ],
      ),
    );
  }
}

/// Series tab: newest-added series first.
class _NewSeriesTab extends ConsumerWidget {
  const _NewSeriesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(allSeriesProvider);
    final adultIds = ref.watch(adultSeriesIdsProvider).value ?? const <String>{};
    final adultCats = ref.watch(adultSeriesCategoryIdsProvider).value ?? const <String>{};

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) {
        final items = list
            .where((s) => !adultIds.contains(s.seriesId) && !adultCats.contains(s.categoryId))
            .toList()
          ..sort((a, b) => b.added.compareTo(a.added));
        final top = items.take(120).toList();
        if (top.isEmpty) return const Center(child: Text('No new series.'));
        return _grid(
          context,
          top.length,
          (i) => _Poster(
            name: top[i].name,
            image: top[i].coverUrl,
            onTap: () => context.push('/series/${top[i].seriesId}'),
          ),
        );
      },
    );
  }
}

/// Movies tab: newest-added movies first.
class _NewMoviesTab extends ConsumerWidget {
  const _NewMoviesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(allVodProvider);
    final adultIds = ref.watch(adultVodIdsProvider).value ?? const <String>{};
    final adultCats = ref.watch(adultVodCategoryIdsProvider).value ?? const <String>{};

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) {
        final items = list
            .where((v) => !adultIds.contains(v.streamId) && !adultCats.contains(v.categoryId))
            .toList()
          ..sort((a, b) => b.added.compareTo(a.added));
        final top = items.take(120).toList();
        if (top.isEmpty) return const Center(child: Text('No new movies.'));
        return _grid(
          context,
          top.length,
          (i) => _Poster(
            name: top[i].name,
            image: top[i].posterUrl,
            onTap: () => context.push('/vod/${top[i].streamId}'),
          ),
        );
      },
    );
  }
}

Widget _grid(BuildContext context, int count, Widget Function(int) builder) {
  return GridView.builder(
    padding: const EdgeInsets.all(16),
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: GridMetrics.posterExtent,
      childAspectRatio: 0.62,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    ),
    itemCount: count,
    itemBuilder: (context, i) => builder(i),
  );
}

class _Poster extends StatelessWidget {
  const _Poster({required this.name, required this.image, required this.onTap});

  final String name;
  final String? image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: image != null
                  ? CachedNetworkImage(
                      imageUrl: image!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorWidget: (_, _, _) => Container(
                        color: AppColors.surface,
                        child: const Icon(Icons.image_not_supported_outlined),
                      ),
                    )
                  : Container(
                      color: AppColors.surface,
                      child: const Icon(Icons.movie_outlined),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
