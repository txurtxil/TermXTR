import 'package:linux_container/src/container/container_manager.dart';
import 'dart:async';

void main() async {
  final manager = ContainerManager();
  print('--- Iniciando Prueba de Integración ---');
  
  print('Probando: ls -la /');
  
  // Usamos un timeout para evitar que el test se quede colgado si el contenedor no responde
  final result = await manager.executeCommandStream('ls -la /').toList().timeout(const Duration(seconds: 10));
  
  if (result.isNotEmpty) {
    print('✅ ÉXITO: El contenedor respondió con ${result.length} líneas.');
    for (var line in result.take(10)) {
      print('  > $line');
    }
  } else {
    print('❌ ERROR: El contenedor no devolvió ninguna salida.');
  }
}
