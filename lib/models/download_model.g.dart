// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class QualityOptionAdapter extends TypeAdapter<QualityOption> {
  @override
  final int typeId = 11;

  @override
  QualityOption read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return QualityOption(
      quality: fields[0] as String,
      hash: fields[1] as String,
      sizeBytes: fields[2] as int,
      type: fields[3] as String?,
      videoCodec: fields[4] as String?,
      audioChannels: fields[5] as String?,
      source: fields[6] as String,
      seeders: fields[7] as int,
      telegramFileId: fields[8] as int?,
      channelName: fields[9] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, QualityOption obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.quality)
      ..writeByte(1)
      ..write(obj.hash)
      ..writeByte(2)
      ..write(obj.sizeBytes)
      ..writeByte(3)
      ..write(obj.type)
      ..writeByte(4)
      ..write(obj.videoCodec)
      ..writeByte(5)
      ..write(obj.audioChannels)
      ..writeByte(6)
      ..write(obj.source)
      ..writeByte(7)
      ..write(obj.seeders)
      ..writeByte(8)
      ..write(obj.telegramFileId)
      ..writeByte(9)
      ..write(obj.channelName);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QualityOptionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DownloadTaskAdapter extends TypeAdapter<DownloadTask> {
  @override
  final int typeId = 12;

  @override
  DownloadTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadTask(
      id: fields[0] as String,
      tmdbId: fields[1] as int,
      title: fields[2] as String,
      mediaType: fields[3] as String,
      season: fields[4] as int?,
      episode: fields[5] as int?,
      episodeName: fields[6] as String?,
      quality: fields[7] as String,
      posterPath: fields[8] as String?,
      status: fields[9] as DownloadStatus,
      progress: fields[10] as double,
      filePath: fields[11] as String?,
      error: fields[12] as String?,
      createdAt: fields[13] as DateTime,
      fileSizeBytes: fields[14] as int,
      audioChannels: fields[15] as String?,
      videoCodec: fields[16] as String?,
      downloadedBytes: fields[17] as int,
      imdbId: fields[18] as String,
      source: fields[19] as String,
      telegramFileId: fields[20] as int?,
      downloadSpeed: fields[21] as double,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadTask obj) {
    writer
      ..writeByte(22)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tmdbId)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.mediaType)
      ..writeByte(4)
      ..write(obj.season)
      ..writeByte(5)
      ..write(obj.episode)
      ..writeByte(6)
      ..write(obj.episodeName)
      ..writeByte(7)
      ..write(obj.quality)
      ..writeByte(8)
      ..write(obj.posterPath)
      ..writeByte(9)
      ..write(obj.status)
      ..writeByte(10)
      ..write(obj.progress)
      ..writeByte(11)
      ..write(obj.filePath)
      ..writeByte(12)
      ..write(obj.error)
      ..writeByte(13)
      ..write(obj.createdAt)
      ..writeByte(14)
      ..write(obj.fileSizeBytes)
      ..writeByte(15)
      ..write(obj.audioChannels)
      ..writeByte(16)
      ..write(obj.videoCodec)
      ..writeByte(17)
      ..write(obj.downloadedBytes)
      ..writeByte(18)
      ..write(obj.imdbId)
      ..writeByte(19)
      ..write(obj.source)
      ..writeByte(20)
      ..write(obj.telegramFileId)
      ..writeByte(21)
      ..write(obj.downloadSpeed);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DownloadStatusAdapter extends TypeAdapter<DownloadStatus> {
  @override
  final int typeId = 10;

  @override
  DownloadStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return DownloadStatus.queued;
      case 1:
        return DownloadStatus.searching;
      case 2:
        return DownloadStatus.downloading;
      case 3:
        return DownloadStatus.converting;
      case 4:
        return DownloadStatus.completed;
      case 5:
        return DownloadStatus.failed;
      case 6:
        return DownloadStatus.paused;
      default:
        return DownloadStatus.queued;
    }
  }

  @override
  void write(BinaryWriter writer, DownloadStatus obj) {
    switch (obj) {
      case DownloadStatus.queued:
        writer.writeByte(0);
        break;
      case DownloadStatus.searching:
        writer.writeByte(1);
        break;
      case DownloadStatus.downloading:
        writer.writeByte(2);
        break;
      case DownloadStatus.converting:
        writer.writeByte(3);
        break;
      case DownloadStatus.completed:
        writer.writeByte(4);
        break;
      case DownloadStatus.failed:
        writer.writeByte(5);
        break;
      case DownloadStatus.paused:
        writer.writeByte(6);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
