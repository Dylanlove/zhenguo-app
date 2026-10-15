import 'package:flutter/material.dart';

class PlayerChromeTitle extends StatelessWidget {
  const PlayerChromeTitle({
    super.key,
    required this.title,
    required this.subtitle,
    this.titleSize = 18,
    this.subtitleSize = 12.5,
  });

  final String title;
  final String subtitle;
  final double titleSize;
  final double subtitleSize;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontSize: titleSize,
          fontWeight: FontWeight.w600,
          height: 1.2,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
        ),
      ),
      const SizedBox(height: 4),
      Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: const Color(0xB8FFFFFF),
          fontSize: subtitleSize,
          fontWeight: FontWeight.w400,
          height: 1.2,
        ),
      ),
    ],
  );
}

class PlayerEpisodeCounter extends StatelessWidget {
  const PlayerEpisodeCounter({
    super.key,
    required this.number,
    required this.count,
    this.numberSize = 42,
    this.labelSize = 12.5,
    this.countSize = 13,
    this.leftInset = 6,
  });

  final int number;
  final int count;
  final double numberSize;
  final double labelSize;
  final double countSize;
  final double leftInset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: leftInset),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.bottomLeft,
      child: Text.rich(
        TextSpan(
          style: TextStyle(
            color: Colors.white,
            fontSize: labelSize,
            height: 1,
            fontWeight: FontWeight.w500,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
          ),
          children: [
            const TextSpan(text: '第 '),
            TextSpan(
              text: '$number',
              style: TextStyle(fontSize: numberSize),
            ),
            const TextSpan(text: ' 集'),
            TextSpan(
              text: ' / $count',
              style: TextStyle(
                color: const Color(0xB8FFFFFF),
                fontSize: countSize,
              ),
            ),
          ],
        ),
        semanticsLabel: '第 $number 集，共 $count 集',
        maxLines: 1,
      ),
    ),
  );
}

LinearGradient playerChromeGradient({
  required double height,
  required double topInset,
  required double bottomInset,
  double topExtent = 80,
  double bottomExtent = 160,
  double bottomHoldExtent = 80,
  double bottomStartLimit = .6,
}) {
  final topEnd = ((topInset + topExtent) / height).clamp(0.0, .4);
  final topHold = ((topInset + 44) / height).clamp(0.0, topEnd);
  final bottomStart = (1 - (bottomInset + bottomExtent) / height).clamp(
    bottomStartLimit,
    1.0,
  );
  final bottomHold = (1 - (bottomInset + bottomHoldExtent) / height).clamp(
    bottomStart,
    1.0,
  );
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: const [
      Color(0xC7000000),
      Color(0x8F000000),
      Colors.transparent,
      Colors.transparent,
      Color(0x85000000),
      Color(0xE0000000),
    ],
    stops: [0, topHold, topEnd, bottomStart, bottomHold, 1],
  );
}
