import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'package:syncnote/features/notes/note_editor_screen.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';

/// Top-level helper to calculate orbital anchors for galaxy clusters and solo asteroid belts.
Offset getComponentAnchor(
  int componentId,
  int componentSize,
  double centerX,
  double centerY,
) {
  if (componentSize <= 1) {
    // Unconnected solo notes go to the "Lost Asteroid Belt" at the left-bottom sector
    return Offset(centerX - 950, centerY + 650);
  }

  // Symmetrical spacing avoiding the left-bottom sector (limits angle to [-45 deg, 225 deg])
  final double minAngle = -math.pi / 4;
  final double maxAngle = 5 * math.pi / 4;
  final double range = maxAngle - minAngle;

  // Distribute galaxy anchors evenly in space
  final step = range / 5;
  final angle = minAngle + (componentId % 5) * step;
  const distance =
      800.0; // Pushed further away for high-end cosmos spacious feel
  return Offset(
    centerX + distance * math.cos(angle),
    centerY + distance * math.sin(angle),
  );
}

/// Nebula dust particle configuration
class NebulaDust {
  final double angle;
  final double radiusFactor;
  final double size;
  final double twinkleSpeed;
  final double phase;

  NebulaDust({
    required this.angle,
    required this.radiusFactor,
    required this.size,
    required this.twinkleSpeed,
    required this.phase,
  });
}

class NotesGraphScreen extends StatefulWidget {
  const NotesGraphScreen({super.key});

  @override
  State<NotesGraphScreen> createState() => _NotesGraphScreenState();
}

class _NotesGraphScreenState extends State<NotesGraphScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  List<GraphNode> _nodes = [];
  final List<GraphEdge> _edges = [];
  bool _initialized = false;

  // Viewport camera zoom/pan states
  Offset _panOffset = Offset.zero;
  double _zoomScale = 1.0;

  // Cinematic smooth tracking targets
  Offset _targetPanOffset = Offset.zero;
  double _targetZoomScale = 1.0;

  // Map of local rotations for each galaxy (componentId -> Offset(localAngleX, localAngleY))
  // Lost Sector is key -1
  final Map<int, Offset> _galaxyRotations = {};

  // Component currently selected for 3D rotation dragging
  int? _activeRotationComponentId;

  // Dynamic galaxy core anchors in simulation space
  final Map<int, Offset> _galaxyCores = {};

  // Pre-generated static nebula dust mapping
  final Map<int, List<NebulaDust>> _nebulaDustMap = {};

  // Selected node being dragged
  GraphNode? _draggedNode;

  // Search state
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  List<GraphNode> _searchResults = [];

  // Locating radar animation
  String? _pulsingNodeId;
  double _pulseAnimTime = 0.0;

  // Animation and background particle elements
  Duration _elapsedDuration = Duration.zero;
  List<BackgroundStar> _stars = [];
  Size _lastSize = const Size(800, 600);

  // Multi-touch pointer tracking
  final Map<int, Offset> _activePointers = {};
  double _initialPointerDistance = 0.0;
  double _initialZoomScale = 1.0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (_initialized) {
        _tickPhysics(_lastSize.width / 2, _lastSize.height / 2);
        _elapsedDuration = elapsed;

        // Cinematic tracking camera glide (smooth linear interpolation)
        _panOffset += (_targetPanOffset - _panOffset) * 0.08;
        _zoomScale += (_targetZoomScale - _zoomScale) * 0.08;

        // Radar pulses fadeout logic
        if (_pulsingNodeId != null) {
          _pulseAnimTime += 0.016; // approx 60fps tick
          if (_pulseAnimTime > 3.0) {
            _pulsingNodeId = null;
            _pulseAnimTime = 0.0;
          }
        }

        setState(() {});
      }
    });
    _ticker.start();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _ticker.dispose();
    super.dispose();
  }

  void _generateStars() {
    if (_stars.isNotEmpty) return;
    final rand = math.Random();
    // Wide starry background: 350 twinkling stars in a massive 5000px coordinate range
    _stars = List.generate(350, (index) {
      return BackgroundStar(
        x: (rand.nextDouble() - 0.5) * 5000,
        y: (rand.nextDouble() - 0.5) * 5000,
        size: 0.8 + rand.nextDouble() * 1.5,
        twinkleSpeed: 0.3 + rand.nextDouble() * 1.5,
        phase: rand.nextDouble() * 2 * math.pi,
      );
    });
  }

  void _ensureNebulaDust(int compId) {
    if (_nebulaDustMap.containsKey(compId)) return;
    final rand = math.Random();
    // 130 particles for Lost Sector (-1), 75 for active galaxy components
    final count = compId == -1 ? 130 : 75;
    _nebulaDustMap[compId] = List.generate(count, (index) {
      return NebulaDust(
        angle: rand.nextDouble() * 2 * math.pi,
        radiusFactor: rand
            .nextDouble(), // 360-degree radial scattering filling entire sector
        size:
            16.0 +
            rand.nextDouble() * 20.0, // wide gas particles (16px to 36px)
        twinkleSpeed: 0.4 + rand.nextDouble() * 1.3,
        phase: rand.nextDouble() * 2 * math.pi,
      );
    });
  }

  void _initializePositions(List<Note> notes, Size size) {
    if (_initialized) return;

    final rand = math.Random();
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    _nodes = notes.map((note) {
      final r = 60 + rand.nextDouble() * 240;
      final angle = rand.nextDouble() * 2 * math.pi;
      final z = (rand.nextDouble() - 0.5) * 90.0; // height off galaxy plane
      return GraphNode(
        id: note.id,
        title: note.title.isEmpty ? '无标题' : note.title,
        note: note,
        x: centerX + r * math.cos(angle),
        y: centerY + r * math.sin(angle),
        z: z,
      );
    }).toList();

    _buildEdges();
    _initialized = true;
  }

  void _buildEdges() {
    _edges.clear();

    for (int i = 0; i < _nodes.length; i++) {
      final node = _nodes[i];
      for (final targetId in node.note.linkedNoteIds) {
        final targetIdx = _nodes.indexWhere((n) => n.id == targetId);

        if (targetIdx != -1 && targetIdx != i) {
          final alreadyExists = _edges.any(
            (e) =>
                (e.sourceIndex == i && e.targetIndex == targetIdx) ||
                (e.sourceIndex == targetIdx && e.targetIndex == i),
          );
          if (!alreadyExists) {
            _edges.add(GraphEdge(i, targetIdx));
          }
        }
      }
    }

    // Connected Components calculation (BFS)
    final List<bool> visited = List.filled(_nodes.length, false);
    int currentComponent = 0;

    for (int i = 0; i < _nodes.length; i++) {
      if (!visited[i]) {
        final List<int> queue = [i];
        visited[i] = true;
        final List<int> componentMembers = [];

        while (queue.isNotEmpty) {
          final curr = queue.removeAt(0);
          componentMembers.add(curr);

          for (final edge in _edges) {
            int neighbor = -1;
            if (edge.sourceIndex == curr) {
              neighbor = edge.targetIndex;
            } else if (edge.targetIndex == curr) {
              neighbor = edge.sourceIndex;
            }
            if (neighbor != -1 && !visited[neighbor]) {
              visited[neighbor] = true;
              queue.add(neighbor);
            }
          }
        }

        final size = componentMembers.length;
        for (final idx in componentMembers) {
          _nodes[idx].componentId = currentComponent;
          _nodes[idx].componentSize = size;
        }
        currentComponent++;
      }
    }

    // Initialize anchors and rotations for newly generated components
    final centerX = _lastSize.width / 2;
    final centerY = _lastSize.height / 2;

    // Always ensure Lost Sector dust
    _ensureNebulaDust(-1);

    for (final node in _nodes) {
      if (node.componentSize > 1) {
        _galaxyCores.putIfAbsent(
          node.componentId,
          () => getComponentAnchor(
            node.componentId,
            node.componentSize,
            centerX,
            centerY,
          ),
        );
        _galaxyRotations.putIfAbsent(
          node.componentId,
          () => const Offset(0.35, 0.0),
        );
        _ensureNebulaDust(node.componentId);
      }
    }
  }

  void _tickPhysics(double centerX, double centerY) {
    if (_nodes.isEmpty) return;

    // --- Double-Layer galaxy core physics simulation ---
    final Map<int, Offset> coreForces = {};
    for (final compId in _galaxyCores.keys) {
      coreForces[compId] = Offset.zero;
    }

    // 1. Repulsion between galaxy cores
    final keys = _galaxyCores.keys.toList();
    for (int i = 0; i < keys.length; i++) {
      for (int j = i + 1; j < keys.length; j++) {
        final idA = keys[i];
        final idB = keys[j];
        final posA = _galaxyCores[idA]!;
        final posB = _galaxyCores[idB]!;
        final dx = posB.dx - posA.dx;
        final dy = posB.dy - posA.dy;
        final distSq = dx * dx + dy * dy + 0.01;
        final dist = math.sqrt(distSq);

        if (dist < 800) {
          final force = 220000.0 / distSq; // Strong galactic repulsion
          final fx = (dx / dist) * force;
          final fy = (dy / dist) * force;

          coreForces[idA] = coreForces[idA]! - Offset(fx, fy);
          coreForces[idB] = coreForces[idB]! + Offset(fx, fy);
        }
      }
    }

    // 2. Galaxy core gravity pulling towards viewport center
    for (final compId in _galaxyCores.keys) {
      final pos = _galaxyCores[compId]!;
      final dx = centerX - pos.dx;
      final dy = centerY - pos.dy;
      coreForces[compId] = coreForces[compId]! + Offset(dx * 0.015, dy * 0.015);
    }

    // 3. Update galaxy core positions (velocity capped for stability)
    for (final compId in _galaxyCores.keys) {
      final force = coreForces[compId]!;
      final forceMag = math.sqrt(force.dx * force.dx + force.dy * force.dy);
      final cappedForce = forceMag > 12.0
          ? Offset((force.dx / forceMag) * 12.0, (force.dy / forceMag) * 12.0)
          : force;
      _galaxyCores[compId] = _galaxyCores[compId]! + cappedForce;
    }

    // --- Node-level internal force simulation ---
    // 1. Repulsion between nodes (charge)
    for (int i = 0; i < _nodes.length; i++) {
      for (int j = i + 1; j < _nodes.length; j++) {
        final nodeA = _nodes[i];
        final nodeB = _nodes[j];
        final dx = nodeB.x - nodeA.x;
        final dy = nodeB.y - nodeA.y;
        final distSq = dx * dx + dy * dy + 0.01;
        final dist = math.sqrt(distSq);

        if (dist < 320) {
          double charge = 240.0;
          if (nodeA.componentSize <= 1 && nodeB.componentSize <= 1) {
            charge =
                280.0; // Solo stars spread out nicely inside the Lost Sector
          }
          final force = charge / distSq;
          final fx = (dx / dist) * force;
          final fy = (dy / dist) * force;

          if (!nodeA.isDragged) {
            nodeA.vx -= fx;
            nodeA.vy -= fy;
          }
          if (!nodeB.isDragged) {
            nodeB.vx += fx;
            nodeB.vy += fy;
          }
        }
      }
    }

    // 2. Attraction along edges (springs)
    for (final edge in _edges) {
      if (edge.sourceIndex >= _nodes.length ||
          edge.targetIndex >= _nodes.length) {
        continue;
      }
      final nodeA = _nodes[edge.sourceIndex];
      final nodeB = _nodes[edge.targetIndex];
      final dx = nodeB.x - nodeA.x;
      final dy = nodeB.y - nodeA.y;
      final dist = math.sqrt(dx * dx + dy * dy) + 0.01;

      final force = 0.04 * (dist - 120.0);
      final fx = (dx / dist) * force;
      final fy = (dy / dist) * force;

      if (!nodeA.isDragged) {
        nodeA.vx += fx;
        nodeA.vy += fy;
      }
      if (!nodeB.isDragged) {
        nodeB.vx -= fx;
        nodeB.vy -= fy;
      }
    }

    // 3. Pull nodes to their respective dynamic core anchors / Lost Sector anchor
    for (final node in _nodes) {
      if (node.isDragged) continue;

      final Offset anchor = node.componentSize <= 1
          ? getComponentAnchor(-1, 0, centerX, centerY)
          : (_galaxyCores[node.componentId] ??
                getComponentAnchor(
                  node.componentId,
                  node.componentSize,
                  centerX,
                  centerY,
                ));

      final dx = anchor.dx - node.x;
      final dy = anchor.dy - node.y;

      node.vx += dx * 0.006;
      node.vy += dy * 0.006;

      // Friction damping
      node.vx *= 0.85;
      node.vy *= 0.85;

      node.x += node.vx;
      node.y += node.vy;
    }
  }

  void _onPanStart(Offset localPosition, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Projected coordinate hit testing (scales/pan offset removed mathematically correctly)
    final projHitPos = Offset(
      cx + (localPosition.dx - cx - _panOffset.dx) / _zoomScale,
      cy + (localPosition.dy - cy - _panOffset.dy) / _zoomScale,
    );

    GraphNode? hitNode;
    double minDist = 30.0;

    for (final node in _nodes) {
      final dx = node.projX - projHitPos.dx;
      final dy = node.projY - projHitPos.dy;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < minDist) {
        minDist = dist;
        hitNode = node;
      }
    }

    if (hitNode != null) {
      hitNode.isDragged = true;
      hitNode.vx = 0;
      hitNode.vy = 0;
      _draggedNode = hitNode;
      _activeRotationComponentId = null;
    } else {
      // Find the closest galaxy or Lost Sector to drag for local 3D rotations
      int closestCompId = -1;
      double minComponentDist = double.infinity;

      final lostCenter = getComponentAnchor(-1, 0, cx, cy);
      final distLost = (lostCenter - projHitPos).distance;
      if (distLost < minComponentDist) {
        minComponentDist = distLost;
        closestCompId = -1;
      }

      for (final compId in _galaxyCores.keys) {
        final coreCenter = _galaxyCores[compId]!;
        final distCore = (coreCenter - projHitPos).distance;
        if (distCore < minComponentDist) {
          minComponentDist = distCore;
          closestCompId = compId;
        }
      }

      _activeRotationComponentId = closestCompId;
    }
  }

  void _onPanUpdate(Offset localPosition, Offset delta, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Projected coordinate hit testing (scales/pan offset removed mathematically correctly)
    final projHitPos = Offset(
      cx + (localPosition.dx - cx - _panOffset.dx) / _zoomScale,
      cy + (localPosition.dy - cy - _panOffset.dy) / _zoomScale,
    );

    if (_draggedNode != null) {
      final int compId = _draggedNode!.componentSize <= 1
          ? -1
          : _draggedNode!.componentId;
      final Offset anchor = _draggedNode!.componentSize <= 1
          ? getComponentAnchor(-1, 0, cx, cy)
          : (_galaxyCores[_draggedNode!.componentId] ??
                getComponentAnchor(
                  _draggedNode!.componentId,
                  _draggedNode!.componentSize,
                  cx,
                  cy,
                ));

      final rot = _galaxyRotations[compId] ?? const Offset(0.35, 0.0);
      final double angleX = rot.dx;
      final double angleY = rot.dy;

      final scale = _draggedNode!.projScale;
      // Coordinates calculated relative to its local dynamic anchor (pivot corrected)
      final rotX = (projHitPos.dx - anchor.dx) / scale;
      final rotY = (projHitPos.dy - anchor.dy) / scale;
      final rotZ = _draggedNode!.projDepth;

      // Reverse matrix 3D rotation projection for the local galaxy coordinates
      final cosX = math.cos(angleX);
      final sinX = math.sin(angleX);
      final cosY = math.cos(angleY);
      final sinY = math.sin(angleY);

      // Rotate around X-axis by -angleX
      final y1 = rotY * cosX + rotZ * sinX;
      final z1 = -rotY * sinX + rotZ * cosX;
      final x1 = rotX;

      // Rotate around Y-axis by -angleY
      final dx = x1 * cosY + z1 * sinY;
      final dz = -x1 * sinY + z1 * cosY;
      final dy = y1;

      _draggedNode!.x = anchor.dx + dx;
      _draggedNode!.y = anchor.dy + dy;
      _draggedNode!.z = dz;
    } else if (_activeRotationComponentId != null) {
      // Dragging empty space rotates the SELECTED galaxy or Lost Sector in 3D locally
      final compId = _activeRotationComponentId!;
      final currentRot = _galaxyRotations[compId] ?? const Offset(0.35, 0.0);

      final newAngleY = currentRot.dy + delta.dx * 0.005;
      final newAngleX = (currentRot.dx - delta.dy * 0.005).clamp(
        -math.pi / 2.2,
        math.pi / 2.2,
      );

      setState(() {
        _galaxyRotations[compId] = Offset(newAngleX, newAngleY);
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_draggedNode != null) {
      _draggedNode!.isDragged = false;
      _draggedNode = null;
    }
    _activeRotationComponentId = null;
  }

  void _onTapUp(TapUpDetails details, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Projected coordinate hit testing (scales/pan offset removed mathematically correctly)
    final projHitPos = Offset(
      cx + (details.localPosition.dx - cx - _panOffset.dx) / _zoomScale,
      cy + (details.localPosition.dy - cy - _panOffset.dy) / _zoomScale,
    );

    for (final node in _nodes) {
      final dx = node.projX - projHitPos.dx;
      final dy = node.projY - projHitPos.dy;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 32.0) {
        // Slightly increased hit size for extra reliability
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => NoteEditorScreen(note: node.note),
          ),
        );
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF02040A),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: const Text(
          '知识网状图谱',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          // Glassmorphic Search Bar overlaying on AppBar
          Container(
            margin: const EdgeInsets.only(right: 16),
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _isSearching ? 240 : 40,
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _isSearching ? Icons.close : Icons.search,
                      color: Colors.white70,
                      size: 18,
                    ),
                    onPressed: () {
                      setState(() {
                        if (_isSearching) {
                          _isSearching = false;
                          _searchController.clear();
                          _searchResults.clear();
                        } else {
                          _isSearching = true;
                        }
                      });
                    },
                  ),
                  if (_isSearching)
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        contextMenuBuilder:
                            AiContextMenuHelper.editableTextContextMenuBuilder,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        decoration: const InputDecoration(
                          hintText: '搜索星空笔记...',
                          hintStyle: TextStyle(
                            color: Colors.white30,
                            fontSize: 13,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.only(bottom: 12),
                        ),
                        onChanged: (val) {
                          setState(() {
                            if (val.isEmpty) {
                              _searchResults.clear();
                            } else {
                              _searchResults = _nodes
                                  .where(
                                    (n) => n.title.toLowerCase().contains(
                                      val.toLowerCase(),
                                    ),
                                  )
                                  .toList();
                            }
                          });
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<Note>>(
        stream: FirestoreService.instance.watchNotes(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !_initialized) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          final notes = snapshot.data ?? [];
          if (notes.isEmpty) {
            return const Center(
              child: Text(
                '暂无笔记，添加笔记及 Wiki 引用以点亮星空图谱',
                style: TextStyle(color: Colors.white60),
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              _lastSize = size;
              _initializePositions(notes, size);
              _generateStars();

              return Stack(
                children: [
                  // Core viewport
                  Listener(
                    onPointerSignal: (pointerSignal) {
                      if (pointerSignal is PointerScrollEvent) {
                        setState(() {
                          final delta = pointerSignal.scrollDelta.dy;
                          _targetZoomScale = (_targetZoomScale - delta * 0.0012)
                              .clamp(0.15, 4.0);
                        });
                      }
                    },
                    onPointerDown: (event) {
                      setState(() {
                        _activePointers[event.pointer] = event.localPosition;
                        if (_activePointers.length == 1) {
                          _onPanStart(event.localPosition, size);
                        } else if (_activePointers.length == 2) {
                          // Cancel any single-pointer drag/rotate to prevent jumping
                          if (_draggedNode != null) {
                            _draggedNode!.isDragged = false;
                            _draggedNode = null;
                          }
                          _activeRotationComponentId = null;

                          final keys = _activePointers.keys.toList();
                          _initialPointerDistance =
                              (_activePointers[keys[0]]! -
                                      _activePointers[keys[1]]!)
                                  .distance;
                          _initialZoomScale = _targetZoomScale;
                        }
                      });
                    },
                    onPointerMove: (event) {
                      setState(() {
                        _activePointers[event.pointer] = event.localPosition;
                        if (_activePointers.length == 1) {
                          if (event.buttons == kSecondaryMouseButton) {
                            _targetPanOffset += event.delta;
                          } else {
                            _onPanUpdate(
                              event.localPosition,
                              event.delta,
                              size,
                            );
                          }
                        } else if (_activePointers.length == 2) {
                          final keys = _activePointers.keys.toList();
                          final currentDistance =
                              (_activePointers[keys[0]]! -
                                      _activePointers[keys[1]]!)
                                  .distance;
                          if (_initialPointerDistance > 0) {
                            final double scaleRatio =
                                currentDistance / _initialPointerDistance;
                            _targetZoomScale = (_initialZoomScale * scaleRatio)
                                .clamp(0.15, 4.0);
                          }
                          _targetPanOffset += event.delta;
                        }
                      });
                    },
                    onPointerUp: (event) {
                      setState(() {
                        _activePointers.remove(event.pointer);
                        if (_activePointers.isEmpty) {
                          _onPanEnd(DragEndDetails());
                        } else if (_activePointers.length == 1) {
                          // Resume single pointer drag/rotate on the remaining touch point
                          _onPanStart(_activePointers.values.first, size);
                        }
                      });
                    },
                    onPointerCancel: (event) {
                      setState(() {
                        _activePointers.remove(event.pointer);
                        if (_activePointers.isEmpty) {
                          _onPanEnd(DragEndDetails());
                        }
                      });
                    },
                    child: GestureDetector(
                      onTapUp: (d) => _onTapUp(d, size),
                      child: CustomPaint(
                        size: size,
                        painter: GraphPainter(
                          nodes: _nodes,
                          edges: _edges,
                          panOffset: _panOffset,
                          zoomScale: _zoomScale,
                          stars: _stars,
                          elapsedDuration: _elapsedDuration,
                          galaxyCores: _galaxyCores,
                          pulsingNodeId: _pulsingNodeId,
                          pulseAnimTime: _pulseAnimTime,
                          galaxyRotations: _galaxyRotations,
                          nebulaDustMap: _nebulaDustMap,
                        ),
                      ),
                    ),
                  ),

                  // Floating glassmorphic search results list
                  if (_isSearching && _searchResults.isNotEmpty)
                    Positioned(
                      top: kToolbarHeight + 20,
                      right: 16,
                      child: Container(
                        width: 240,
                        constraints: const BoxConstraints(maxHeight: 260),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF0D1117,
                          ).withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.6),
                              blurRadius: 12,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: _searchResults.length,
                            itemBuilder: (context, index) {
                              final node = _searchResults[index];
                              return ListTile(
                                dense: true,
                                title: Text(
                                  node.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  node.componentSize <= 1
                                      ? '遗落孤星'
                                      : '所属星系 #${node.componentId}',
                                  style: TextStyle(
                                    color: node.componentSize <= 1
                                        ? const Color(
                                            0xFFFBBF24,
                                          ).withValues(alpha: 0.6)
                                        : Colors.white60,
                                    fontSize: 10,
                                  ),
                                ),
                                onTap: () {
                                  // Cinematic camera smooth tracking targeting
                                  final cx = size.width / 2;
                                  final cy = size.height / 2;
                                  setState(() {
                                    _targetZoomScale = 1.4;
                                    _targetPanOffset =
                                        Offset(cx - node.x, cy - node.y) * 1.4;
                                    _pulsingNodeId = node.id;
                                    _pulseAnimTime = 0.0;
                                    _isSearching = false;
                                    _searchController.clear();
                                    _searchResults.clear();
                                  });
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class GraphNode {
  final String id;
  final String title;
  final Note note;
  double x;
  double y;
  double z;
  double vx = 0;
  double vy = 0;
  bool isDragged = false;
  int componentId = 0;
  int componentSize = 1;

  // Realtime 3D projected coordinates computed in paint
  double projX = 0;
  double projY = 0;
  double projScale = 1.0;
  double projDepth = 0.0;

  GraphNode({
    required this.id,
    required this.title,
    required this.note,
    required this.x,
    required this.y,
    required this.z,
  });
}

class GraphEdge {
  final int sourceIndex;
  final int targetIndex;

  GraphEdge(this.sourceIndex, this.targetIndex);
}

class BackgroundStar {
  final double x;
  final double y;
  final double size;
  final double twinkleSpeed;
  final double phase;

  BackgroundStar({
    required this.x,
    required this.y,
    required this.size,
    required this.twinkleSpeed,
    required this.phase,
  });
}

class GraphPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final Offset panOffset;
  final double zoomScale;
  final List<BackgroundStar> stars;
  final Duration elapsedDuration;
  final Map<int, Offset> galaxyCores;
  final String? pulsingNodeId;
  final double pulseAnimTime;
  final Map<int, Offset> galaxyRotations;
  final Map<int, List<NebulaDust>> nebulaDustMap;

  GraphPainter({
    required this.nodes,
    required this.edges,
    required this.panOffset,
    required this.zoomScale,
    required this.stars,
    required this.elapsedDuration,
    required this.galaxyCores,
    required this.pulsingNodeId,
    required this.pulseAnimTime,
    required this.galaxyRotations,
    required this.nebulaDustMap,
  });

  Color _getNodeColor(int componentId, int componentSize) {
    if (componentSize <= 1) {
      // Drifting solo star is rendered with bright gold
      return const Color(0xFFFBBF24);
    }
    final colors = [
      const Color(0xFF10B981), // Emerald Green
      const Color(0xFFEC4899), // Dusty Pink / Magenta
      const Color(0xFF06B6D4), // Electric Cyan
      const Color(0xFF8B5CF6), // Magic Violet
      const Color(0xFFF59E0B), // Golden Amber
      const Color(0xFF3B82F6), // Deep Sky Blue
    ];
    return colors[componentId % colors.length];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double elapsedSec = elapsedDuration.inMilliseconds / 1000.0;
    final center = Offset(size.width / 2, size.height / 2);

    // 1. Draw space background deep black radial gradient
    final bgPaint = Paint();
    final bgGrad = RadialGradient(
      center: Alignment.center,
      radius: 1.5,
      colors: const [
        Color(0xFF050711), // Deep navy center
        Color(0xFF010204), // Obsidian black edges
      ],
    );
    bgPaint.shader = bgGrad.createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bgPaint);

    // Draw full-screen ambient gas nebula dust layer
    final ambientPaint = Paint()..blendMode = BlendMode.plus;
    final ambientGrad = RadialGradient(
      center: Alignment.center,
      radius: 1.3,
      colors: [
        const Color(0xFF0F172A).withValues(alpha: 0.16),
        const Color(0xFF1E1B4B).withValues(alpha: 0.06),
        Colors.transparent,
      ],
    );
    ambientPaint.shader = ambientGrad.createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, ambientPaint);

    // 2. Draw sparkling Background Stars (with 3D Spherical Specular lighting & 3D Parallax motion effect)
    final parallaxOffset = panOffset * 0.28; // Stars float at 28% scroll speed
    final starZoomFactor =
        1.0 + (zoomScale - 1.0) * 0.12; // Stars zoom at 12% rate
    for (final star in stars) {
      final opacity =
          0.15 +
          0.65 * math.sin(elapsedSec * star.twinkleSpeed + star.phase).abs();
      final Offset sPos = Offset(
        center.dx + (star.x * starZoomFactor) + parallaxOffset.dx,
        center.dy + (star.y * starZoomFactor) + parallaxOffset.dy,
      );

      final starPaint = Paint();
      starPaint.shader = RadialGradient(
        center: const Alignment(-0.35, -0.35),
        radius: 0.9,
        colors: [
          Colors.white.withValues(alpha: opacity),
          const Color(0xFFE2E8F0).withValues(alpha: opacity * 0.8),
          const Color(0xFF475569).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: sPos, radius: star.size));
      canvas.drawCircle(sPos, star.size, starPaint);
    }

    // 3. Compute 3D Perspective Projection for all nodes based on LOCAL rotations
    const double cameraDist = 900.0; // Focal distance

    for (final node in nodes) {
      final int compId = node.componentSize <= 1 ? -1 : node.componentId;
      final rot = galaxyRotations[compId] ?? const Offset(0.35, 0.0);
      final double angleX = rot.dx;
      final double angleY = rot.dy;

      final Offset anchor = node.componentSize <= 1
          ? getComponentAnchor(-1, 0, center.dx, center.dy)
          : (galaxyCores[node.componentId] ??
                getComponentAnchor(
                  node.componentId,
                  node.componentSize,
                  center.dx,
                  center.dy,
                ));

      final dx = node.x - anchor.dx;
      final dy = node.y - anchor.dy;
      final dz = node.z;

      // 3D rotation projection Matrix around local anchor
      final double cosX = math.cos(angleX);
      final double sinX = math.sin(angleX);
      final double cosY = math.cos(angleY);
      final double sinY = math.sin(angleY);

      final x1 = dx * cosY - dz * sinY;
      final z1 = dx * sinY + dz * cosY;

      final rotX = x1;
      final rotY = dy * cosX - z1 * sinX;
      final rotZ = dy * sinX + z1 * cosX; // local Z depth

      final scale = cameraDist / (cameraDist - rotZ);

      node.projX = anchor.dx + rotX * scale;
      node.projY = anchor.dy + rotY * scale;
      node.projScale = scale;
      node.projDepth = rotZ;
    }

    canvas.save();

    // Global translation & zoom around viewport center in simulation space
    canvas.translate(center.dx + panOffset.dx, center.dy + panOffset.dy);
    canvas.scale(zoomScale);
    canvas.translate(-center.dx, -center.dy);

    // 4. Draw Organic twinking Nebula Volumetric Gas Clouds for each component (replacing solid rings)
    // Gather all components to draw their fuzzy dust rings
    final Set<int> allComps = {-1}; // Always Lost Sector
    for (final node in nodes) {
      if (node.componentSize > 1) {
        allComps.add(node.componentId);
      }
    }

    for (final compId in allComps) {
      final List<NebulaDust>? dustList = nebulaDustMap[compId];
      if (dustList == null || dustList.isEmpty) continue;

      final Offset anchor = compId == -1
          ? getComponentAnchor(-1, 0, center.dx, center.dy)
          : (galaxyCores[compId] ??
                getComponentAnchor(compId, 2, center.dx, center.dy));

      final color = compId == -1
          ? const Color(0xFFFBBF24)
          : _getNodeColor(compId, 2);

      // Calculate radius of component nebula dust ring
      double rad = 100.0;
      if (compId == -1) {
        final int soloCount = nodes.where((n) => n.componentSize <= 1).length;
        rad = 240.0 + math.sqrt(soloCount) * 48.0;
      }

      final rot = galaxyRotations[compId] ?? const Offset(0.35, 0.0);
      final double cosX = math.cos(rot.dx);
      final double sinX = math.sin(rot.dx);
      final double cosY = math.cos(rot.dy);
      final double sinY = math.sin(rot.dy);

      for (final dust in dustList) {
        final double pRadius = rad * dust.radiusFactor;
        final double pdx = pRadius * math.cos(dust.angle);
        final double pdy = pRadius * math.sin(dust.angle);
        // Volumetric 3D vertical thickness noise
        final double pdz = math.sin(dust.angle * 2.5) * 16.0;

        // Apply local 3D rotation matrix around its anchor
        final px1 = pdx * cosY - pdz * sinY;
        final pz1 = pdx * sinY + pdz * cosY;
        final protX = px1;
        final protY = pdy * cosX - pz1 * sinX;
        final protZ = pdy * sinX + pz1 * cosX;

        final pScale = cameraDist / (cameraDist - protZ);
        final pProjX = anchor.dx + protX * pScale;
        final pProjY = anchor.dy + protY * pScale;

        // Twinkle factor
        final opacity =
            (0.04 +
                0.3 *
                    math
                        .sin(elapsedSec * dust.twinkleSpeed + dust.phase)
                        .abs()) *
            pScale;
        final double pSize = dust.size * pScale;

        // Draw fuzzy smoky gas cloud (RadialGradient combined with MaskFilter blur)
        final dustPaint = Paint()
          ..blendMode = BlendMode.plus
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 15.0 * pScale);

        dustPaint.shader =
            RadialGradient(
              center: const Alignment(-0.35, -0.35),
              radius: 0.9,
              colors: [
                Colors.white.withValues(alpha: opacity),
                color.withValues(alpha: opacity * 0.8),
                color.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.45, 1.0],
            ).createShader(
              Rect.fromCircle(center: Offset(pProjX, pProjY), radius: pSize),
            );

        canvas.drawCircle(Offset(pProjX, pProjY), pSize, dustPaint);
      }

      // Draw faint label inside the Lost Sector
      if (compId == -1) {
        // Projects Lost Sector label anchor slightly inside 3D
        final lostTextSpan = TextSpan(
          text: '遗落星区\n(独立小行星带)',
          style: TextStyle(
            color: const Color(0xFFFBBF24).withValues(alpha: 0.16),
            fontSize: 12,
            fontWeight: FontWeight.bold,
            height: 1.4,
          ),
        );
        final lostTextPainter = TextPainter(
          text: lostTextSpan,
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();

        // Tilt the label relative to anchor slightly
        lostTextPainter.paint(
          canvas,
          Offset(
            anchor.dx - lostTextPainter.width / 2,
            anchor.dy - lostTextPainter.height / 2,
          ),
        );
      }
    }

    // 5. Draw cluster-specific local nebula star-dust gas clouds
    final localNebulaPaint = Paint()..blendMode = BlendMode.plus;
    for (final node in nodes) {
      if (node.componentSize <= 1) continue;

      final color = _getNodeColor(node.componentId, node.componentSize);
      final double rad = 100.0 * node.projScale;
      final glowColor = color.withValues(alpha: 0.08 * node.projScale);

      localNebulaPaint.shader =
          RadialGradient(colors: [glowColor, Colors.transparent]).createShader(
            Rect.fromCircle(
              center: Offset(node.projX, node.projY),
              radius: rad,
            ),
          );

      canvas.drawCircle(Offset(node.projX, node.projY), rad, localNebulaPaint);
    }

    // 6. Draw Galactic Centers (galaxy cores) at their dynamic physical anchors
    for (final compId in galaxyCores.keys) {
      final anchor = galaxyCores[compId]!;
      final coreColor = _getNodeColor(compId, 2);
      final rot = galaxyRotations[compId] ?? const Offset(0.35, 0.0);

      final double localCosX = math.cos(rot.dx);
      final double localSinX = math.sin(rot.dx);
      final double localCosY = math.cos(rot.dy);
      final double localSinY = math.sin(rot.dy);

      // Projects anchor into rotated 3D camera space to align visually with the cores
      final adx = anchor.dx - center.dx;
      final ady = anchor.dy - center.dy;
      final ax1 = adx * localCosY; // Anchor z is 0
      final az1 = adx * localSinY;
      final aRotX = ax1;
      final aRotY = ady * localCosX - az1 * localSinX;
      final aRotZ = ady * localSinX + az1 * localCosX;

      final aScale = cameraDist / (cameraDist - aRotZ);
      final aProjX = center.dx + aRotX * aScale;
      final aProjY = center.dy + aRotY * aScale;

      final galaxyCorePaint = Paint()..blendMode = BlendMode.plus;
      galaxyCorePaint.shader =
          RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.75),
              coreColor.withValues(alpha: 0.35),
              Colors.transparent,
            ],
            stops: const [0.0, 0.25, 1.0],
          ).createShader(
            Rect.fromCircle(
              center: Offset(aProjX, aProjY),
              radius: 60 * aScale,
            ),
          );

      canvas.drawCircle(Offset(aProjX, aProjY), 60 * aScale, galaxyCorePaint);
    }

    // 7. Draw connection lines & flowing energy particles
    for (final edge in edges) {
      if (edge.sourceIndex >= nodes.length ||
          edge.targetIndex >= nodes.length) {
        continue;
      }
      final nodeA = nodes[edge.sourceIndex];
      final nodeB = nodes[edge.targetIndex];
      final color = _getNodeColor(nodeA.componentId, nodeA.componentSize);

      final edgeGlowPaint = Paint()
        ..color = color.withValues(
          alpha: 0.08 * math.min(nodeA.projScale, nodeB.projScale),
        )
        ..strokeWidth = 3.5
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(nodeA.projX, nodeA.projY),
        Offset(nodeB.projX, nodeB.projY),
        edgeGlowPaint,
      );

      final edgeCorePaint = Paint()
        ..color = color.withValues(
          alpha: 0.28 * math.min(nodeA.projScale, nodeB.projScale),
        )
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(nodeA.projX, nodeA.projY),
        Offset(nodeB.projX, nodeB.projY),
        edgeCorePaint,
      );

      // Energy dot flowing along the line
      final speed =
          0.32 + (math.sin(edge.sourceIndex + edge.targetIndex).abs() * 0.48);
      final t = (elapsedSec * speed) % 1.0;
      final particlePos = Offset(
        nodeA.projX + (nodeB.projX - nodeA.projX) * t,
        nodeA.projY + (nodeB.projY - nodeA.projY) * t,
      );
      final particlePaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(particlePos, 1.8, particlePaint);
    }

    // 8. Draw Nodes (Star points) sorted by Z depth (Painter's algorithm for correct occlusion)
    final sortedNodes = List<GraphNode>.from(nodes)
      ..sort((a, b) => a.projDepth.compareTo(b.projDepth));

    for (final node in sortedNodes) {
      final pos = Offset(node.projX, node.projY);
      final color = _getNodeColor(node.componentId, node.componentSize);

      // Scale sizes based on perspective depth
      final scale = node.projScale;

      if (node.componentSize <= 1) {
        // Solo Star: Golden star with lens flare crosshair spikes and 3D spherical gradient highlight
        final double sphereRadius = 8.5 * scale;

        final glowPaint = Paint()
          ..color = color.withValues(alpha: 0.25 * scale)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(pos, 15.0 * scale, glowPaint);

        final spherePaint = Paint();
        spherePaint.shader = RadialGradient(
          center: const Alignment(-0.35, -0.35),
          radius: 0.9,
          colors: [Colors.white, color, color.withValues(alpha: 0.2)],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: pos, radius: sphereRadius));
        canvas.drawCircle(pos, sphereRadius, spherePaint);

        // Starburst crosshair lines
        final flarePaint = Paint()
          ..color = const Color(0xFFFDE047).withValues(alpha: 0.45 * scale)
          ..strokeWidth = 1.0;
        canvas.drawLine(
          Offset(pos.dx - 12 * scale, pos.dy),
          Offset(pos.dx + 12 * scale, pos.dy),
          flarePaint,
        );
        canvas.drawLine(
          Offset(pos.dx, pos.dy - 12 * scale),
          Offset(pos.dx, pos.dy + 12 * scale),
          flarePaint,
        );
      } else {
        // Constellation Star: Neon colored 3D spherical gradient highlight
        final double sphereRadius = 10.0 * scale;

        final glowPaint1 = Paint()
          ..color = color.withValues(alpha: 0.22 * scale)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(pos, 18.0 * scale, glowPaint1);

        final spherePaint = Paint();
        spherePaint.shader = RadialGradient(
          center: const Alignment(-0.35, -0.35),
          radius: 0.9,
          colors: [Colors.white, color, color.withValues(alpha: 0.25)],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: pos, radius: sphereRadius));

        canvas.drawCircle(pos, sphereRadius, spherePaint);
      }

      // 9. Draw yellow-white tracking radar concentric pulse waves when searching
      if (node.id == pulsingNodeId) {
        final t = (pulseAnimTime * 1.3) % 1.0; // 1.3Hz frequency
        final pulseRadius = (16.0 + 35.0 * t) * scale;
        final pulsePaint = Paint()
          ..color = const Color(
            0xFFFDE047,
          ).withValues(alpha: (1.0 - t) * 0.55 * scale)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(pos, pulseRadius, pulsePaint);

        final innerPulseRadius = (16.0 + 15.0 * t) * scale;
        final innerPulsePaint = Paint()
          ..color = Colors.white.withValues(alpha: (1.0 - t) * 0.3 * scale)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(pos, innerPulseRadius, innerPulsePaint);
      }

      // Dynamic sized glowing text label
      final textSpan = TextSpan(
        text: node.title,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6 + 0.3 * scale),
          fontSize: 9.0 + 1.0 * scale,
          fontWeight: FontWeight.bold,
          shadows: const [
            Shadow(
              blurRadius: 4.0,
              color: Colors.black87,
              offset: Offset(1.0, 1.0),
            ),
          ],
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(node.projX - textPainter.width / 2, node.projY + 12 * scale),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) => true;
}
