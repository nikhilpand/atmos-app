// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class WatchHistoryAdapter extends TypeAdapter<WatchHistory> {
  @override
  final int typeId = 0;

  @override
  WatchHistory read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WatchHistory(
      imdbId: fields[0] as String,
      title: fields[1] as String,
      posterPath: fields[2] as String,
      progressSeconds: fields[3] as int,
      totalSeconds: fields[4] as int,
      lastWatched: fields[5] as DateTime,
      mediaType: fields[6] as String,
      season: fields[7] as int?,
      episode: fields[8] as int?,
      episodeName: fields[9] as String?,
      tmdbId: fields[10] as int,
    );
  }

  @override
  void write(BinaryWriter writer, WatchHistory obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.imdbId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.posterPath)
      ..writeByte(3)
      ..write(obj.progressSeconds)
      ..writeByte(4)
      ..write(obj.totalSeconds)
      ..writeByte(5)
      ..write(obj.lastWatched)
      ..writeByte(6)
      ..write(obj.mediaType)
      ..writeByte(7)
      ..write(obj.season)
      ..writeByte(8)
      ..write(obj.episode)
      ..writeByte(9)
      ..write(obj.episodeName)
      ..writeByte(10)
      ..write(obj.tmdbId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WatchHistoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
