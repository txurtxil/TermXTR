import 'package:linux_container/src/container/container_manager.dart';

void main() async {
  final manager = ContainerManager();
  print('Testing command: ls -la /');
  final result = await manager.executeCommand('ls -la /');
  print(result);
}
