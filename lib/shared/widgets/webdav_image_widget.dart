import 'dart:io';

import 'package:flutter/material.dart';
import 'package:syncnote/shared/services/upload_service.dart';

class WebdavImageWidget extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  const WebdavImageWidget({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    if (!url.startsWith('webdav://')) {
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return Image.network(
          url,
          width: width,
          height: height,
          fit: fit,
          errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
        );
      }

      var cleanPath = url;
      if (cleanPath.startsWith('file:///')) {
        cleanPath = cleanPath.substring(8);
      }
      if (cleanPath.startsWith('/') &&
          cleanPath.length > 2 &&
          cleanPath[2] == ':') {
        cleanPath = cleanPath.substring(1);
      }

      return Image.file(
        File(cleanPath),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
      );
    }

    final notifier = WebdavCacheManager.instance.getStateNotifier(url);
    return ValueListenableBuilder<WebdavCacheState>(
      valueListenable: notifier,
      builder: (context, state, child) {
        return switch (state) {
          WebdavCacheLoading() => Container(
            width: width,
            height: height,
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.05),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          WebdavCacheReady(:final path) => Image.file(
            File(path),
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
          ),
          WebdavCacheFailure(:final message) => _buildDownloadError(
            context,
            message,
          ),
        };
      },
    );
  }

  Widget _buildDownloadError(BuildContext context, String message) {
    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: Tooltip(
          message: message,
          child: IconButton(
            icon: const Icon(Icons.refresh_rounded),
            color: Theme.of(context).colorScheme.error,
            tooltip: '图片加载失败，点击重试',
            onPressed: () => WebdavCacheManager.instance.retry(url),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return SizedBox(
      width: width,
      height: height,
      child: const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
    );
  }
}
