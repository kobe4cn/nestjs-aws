import { Inject, Injectable, OnApplicationShutdown } from '@nestjs/common';
import { DataSource } from 'typeorm';

@Injectable()
export class TypeOrmShutDownService implements OnApplicationShutdown {
  constructor(
    @Inject('TYPEORM_DATASOURCE')
    private readonly dataSources: Map<string, DataSource>,
  ) {}
  async onApplicationShutdown(signal: string) {
    for (const [key, dataSource] of this.dataSources) {
      if (dataSource.isInitialized) {
        console.log('closing', key);
        await dataSource.destroy();
      }
    }
  }
}
