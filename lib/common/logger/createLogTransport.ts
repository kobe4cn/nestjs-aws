export function createLogTransport(level: string, filepath: string) {
  return {
    level: level,
    target: 'pino-roll',
    options: {
      file: filepath,
      frequency: 'hourly',
      dateFormat: 'yyyy.MM.dd',
      mkdir: true,
      size: '10M',
    },
  };
}
export const consoleTransport = {
  level: 'info',
  target: 'pino-pretty',
  options: {
    levelFirst: true,
    colorize: true,
    timestampKey: 'time',
  },
};
