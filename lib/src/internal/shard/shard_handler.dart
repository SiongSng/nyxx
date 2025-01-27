import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:nyxx/src/internal/constants.dart';
import 'package:nyxx/src/internal/interfaces/disposable.dart';
import 'package:nyxx/src/internal/shard/message.dart';

void shardHandler(SendPort sendPort) {
  final runner = ShardRunner(sendPort);

  sendPort.send(runner.receivePort.sendPort);
}

class ShardRunner implements Disposable {
  /// The receive port on which messages from the manager will be received.
  final ReceivePort receivePort = ReceivePort();

  /// A stream on which messages from the manager will be received.
  Stream<ShardMessage<ManagerToShard>> get managerMessages => receivePort.cast<ShardMessage<ManagerToShard>>();

  /// The send port on which messages to the manager should be added;
  final SendPort sendPort;

  /// The current active connection.
  WebSocket? connection;

  /// The subscription to the current active connection.
  StreamSubscription<String>? connectionSubscription;

  /// Whether this shard is currently connected to Discord.
  bool get connected => connection?.readyState == WebSocket.open;

  /// Whether this shard is currently reconnecting.
  ///
  /// [ShardToManager.disconnected] will not be dispatched if this is true.
  bool reconnecting = false;

  ShardRunner(this.sendPort) {
    managerMessages.listen(handle);
  }

  /// Sends a message back to the manager.
  void execute(ShardMessage<ShardToManager> message) => sendPort.send(message);

  /// Handler for uncompressed messages received from Discord.
  ///
  /// Calls jsonDecode and sends the data back to the manager.
  void receive(String payload) => execute(ShardMessage(
        ShardToManager.received,
        data: jsonDecode(payload),
      ));

  /// Handler for incoming messages from the manager.
  Future<void> handle(ShardMessage<ManagerToShard> message) async {
    switch (message.type) {
      case ManagerToShard.send:
        return send(message.data);
      case ManagerToShard.connect:
        return connect(message.data['gatewayHost'] as String, message.data['useCompression'] as bool);
      case ManagerToShard.reconnect:
        return reconnect(message.data['gatewayHost'] as String, message.data['useCompression'] as bool);
      case ManagerToShard.disconnect:
        return disconnect();
      case ManagerToShard.dispose:
        return dispose();
    }
  }

  /// Initiate the connection on this shard.
  ///
  /// Sends [ShardToManager.connected] upon completion.
  Future<void> connect(String gatewayHost, bool useCompression) async {
    if (connected) {
      execute(ShardMessage(ShardToManager.error, data: {'message': 'Shard is already connected'}));
      return;
    }

    try {
      final gatewayUri = Constants.gatewayUri(gatewayHost, useCompression);

      connection = await WebSocket.connect(gatewayUri.toString());
      connection!.pingInterval = const Duration(seconds: 20);

      connection!.done.then((_) {
        if (reconnecting) {
          return;
        }

        execute(ShardMessage(
          ShardToManager.disconnected,
          data: {
            'closeCode': connection!.closeCode!,
            'closeReason': connection!.closeReason,
          },
        ));
      });

      if (useCompression) {
        connectionSubscription = connection!.cast<List<int>>().transform(ZLibDecoder()).transform(utf8.decoder).listen(receive);
      } else {
        connectionSubscription = connection!.cast<String>().listen(receive);
      }

      execute(ShardMessage(ShardToManager.connected));
    } on WebSocketException catch (err) {
      execute(ShardMessage(ShardToManager.error, data: {'message': err.message, 'shouldReconnect': true}));
    } on SocketException catch (err) {
      execute(ShardMessage(ShardToManager.error, data: {'message': err.message, 'shouldReconnect': true}));
    } catch (err) {
      execute(ShardMessage(ShardToManager.error, data: {'message': 'Unhanded exception $err'}));
    }
  }

  /// Reconnect to the server, closing the connection if necessary.
  Future<void> reconnect(String gatewayHost, bool useCompression) async {
    if (reconnecting) {
      execute(ShardMessage(ShardToManager.error, data: {'message': 'Shard is already reconnecting'}));
    }

    reconnecting = true;
    if (connected) {
      // Don't send a normal close code so that the bot doesn't appear offline during the reconnect.
      await disconnect(3001);
    }

    await connect(gatewayHost, useCompression);
    reconnecting = false;
  }

  /// Terminate the connection on this shard.
  ///
  /// Sends [ShardToManager.disconnected].
  Future<void> disconnect([int closeCode = 1000]) async {
    if (!connected) {
      execute(ShardMessage(ShardToManager.error, data: {'message': 'Cannot disconnect shard if no connection is active'}));
    }

    // Closing the connection will trigger the `connection.done` future we listened to when connecting, which will execute the [ShardToManager.disconnected]
    // message.
    await connection!.close(closeCode);
    await connectionSubscription!.cancel();

    connection = null;
    connectionSubscription = null;
  }

  /// Sends data on this shard.
  Future<void> send(dynamic data) async {
    if (!connected) {
      execute(ShardMessage(ShardToManager.error, data: {'message': 'Cannot send data when connection is closed'}));
    }

    connection!.add(jsonEncode(data));
  }

  /// Disposes of this shard.
  ///
  /// Sends [ShardToManager.disposed] upon completion.
  @override
  Future<void> dispose() async {
    if (connected) {
      await disconnect();
    }

    receivePort.close();
    execute(ShardMessage(ShardToManager.disposed));
  }
}
