import 'package:flutter/material.dart';
import 'dart:async';
import '../services/event_bus.dart';

/// Global sync progress banner
/// Shows at the top of the app when syncing pending messages from server
class SyncProgressBanner extends StatefulWidget {
  const SyncProgressBanner({super.key});

  @override
  State<SyncProgressBanner> createState() => _SyncProgressBannerState();
}

class _SyncProgressBannerState extends State<SyncProgressBanner> with SingleTickerProviderStateMixin {
  bool _isVisible = false;
  int _current = 0;
  int _total = 0;
  bool _hasError = false;
  String? _errorMessage;
  
  StreamSubscription? _syncStartedSub;
  StreamSubscription? _syncProgressSub;
  StreamSubscription? _syncCompleteSub;
  StreamSubscription? _syncErrorSub;
  
  late AnimationController _animationController;
  late Animation<double> _heightAnimation;

  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _heightAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    
    _setupListeners();
  }

  void _setupListeners() {
    // Sync started
    _syncStartedSub = EventBus.instance.on<Map<String, dynamic>>(AppEvent.syncStarted).listen((data) {
      if (!mounted) return;
      
      setState(() {
        _isVisible = true;
        _hasError = false;
        _errorMessage = null;
        _total = data['total'] as int? ?? 0;
        _current = 0;
      });
      
      _animationController.forward();
    });
    
    // Sync progress
    _syncProgressSub = EventBus.instance.on<Map<String, dynamic>>(AppEvent.syncProgress).listen((data) {
      if (!mounted) return;
      
      setState(() {
        _current = data['current'] as int? ?? 0;
        _total = data['total'] as int? ?? _total;
      });
    });
    
    // Sync complete
    _syncCompleteSub = EventBus.instance.on<Map<String, dynamic>>(AppEvent.syncComplete).listen((data) {
      if (!mounted) return;
      
      // Show complete state briefly, then hide
      setState(() {
        _current = _total;
      });
      
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        
        _animationController.reverse().then((_) {
          if (mounted) {
            setState(() {
              _isVisible = false;
            });
          }
        });
      });
    });
    
    // Sync error
    _syncErrorSub = EventBus.instance.on<Map<String, dynamic>>(AppEvent.syncError).listen((data) {
      if (!mounted) return;
      
      setState(() {
        _hasError = true;
        _errorMessage = data['error'] as String?;
      });
      
      // Auto-hide after 5 seconds
      Future.delayed(const Duration(seconds: 5), () {
        if (!mounted) return;
        
        _animationController.reverse().then((_) {
          if (mounted) {
            setState(() {
              _isVisible = false;
              _hasError = false;
              _errorMessage = null;
            });
          }
        });
      });
    });
  }

  @override
  void dispose() {
    _syncStartedSub?.cancel();
    _syncProgressSub?.cancel();
    _syncCompleteSub?.cancel();
    _syncErrorSub?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible) return const SizedBox.shrink();
    
    final colorScheme = Theme.of(context).colorScheme;
    final progress = _total > 0 ? _current / _total : 0.0;
    final isComplete = _current >= _total && _total > 0;
    
    return SizeTransition(
      sizeFactor: _heightAnimation,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: _hasError 
              ? colorScheme.errorContainer 
              : (isComplete ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // Icon
                  if (_hasError)
                    Icon(
                      Icons.error_outline,
                      size: 20,
                      color: colorScheme.onErrorContainer,
                    )
                  else if (isComplete)
                    Icon(
                      Icons.check_circle_outline,
                      size: 20,
                      color: colorScheme.onPrimaryContainer,
                    )
                  else
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          colorScheme.primary,
                        ),
                      ),
                    ),
                  
                  const SizedBox(width: 12),
                  
                  // Text
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _hasError
                              ? 'Sync error'
                              : (isComplete ? 'Sync complete!' : 'Syncing messages...'),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: _hasError 
                                ? colorScheme.onErrorContainer 
                                : (isComplete ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant),
                          ),
                        ),
                        if (!_hasError && !isComplete)
                          Text(
                            '$_current of $_total messages',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                        if (_hasError && _errorMessage != null)
                          Text(
                            _errorMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onErrorContainer.withValues(alpha: 0.7),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  
                  // Close button (only for errors)
                  if (_hasError)
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 20,
                        color: colorScheme.onErrorContainer,
                      ),
                      onPressed: () {
                        _animationController.reverse().then((_) {
                          if (mounted) {
                            setState(() {
                              _isVisible = false;
                              _hasError = false;
                              _errorMessage = null;
                            });
                          }
                        });
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
            ),
            
            // Progress bar
            if (!_hasError && !isComplete)
              LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(
                  colorScheme.primary,
                ),
                minHeight: 2,
              ),
          ],
        ),
      ),
    );
  }
}
