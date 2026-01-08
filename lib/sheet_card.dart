import 'package:flutter/material.dart';

class SheetChangesCard extends StatefulWidget {
  final String sheetName;
  final List<Map<String, dynamic>> items;
  final String Function(int? ms) fmtTs;
  final String Function(Map<String, dynamic> cellObj) displayValueOrFormula;

  const SheetChangesCard({
    required this.sheetName,
    required this.items,
    required this.fmtTs,
    required this.displayValueOrFormula,
  });

  @override
  State<SheetChangesCard> createState() => SheetChangesCardState();
}

class SheetChangesCardState extends State<SheetChangesCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final total = widget.items.length;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Sheet header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.sheetName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$total changes',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          const Divider(height: 1),

          // Cells list
          if (_expanded)
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final ch = widget.items[i];
                final a1 = (ch['a1'] ?? '').toString();
                final count = (ch['count'] ?? 1).toString();
                final lastTs = ch['lastTs'] as int?;

                final oldObj =
                    (ch['old'] as Map?)?.cast<String, dynamic>() ?? {};
                final newObj =
                    (ch['new'] as Map?)?.cast<String, dynamic>() ?? {};

                final oldText = widget.displayValueOrFormula(oldObj);
                final newText = widget.displayValueOrFormula(newObj);

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // top row: A1 + meta
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.black26),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              a1.isEmpty ? '(cell)' : a1,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'x$count • ${widget.fmtTs(lastTs)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // diff view: old -> new
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'OLD:',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.black.withOpacity(0.65),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(oldText, style: const TextStyle(fontSize: 13)),
                            const SizedBox(height: 8),
                            Text(
                              'NEW:',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.black.withOpacity(0.65),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(newText, style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
