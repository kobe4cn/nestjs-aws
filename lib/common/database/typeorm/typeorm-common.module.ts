import { Inject, Module, OnApplicationShutdown } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { TypeOrmConfigService } from './typeorm.service';

const dataSources = new Map<string, DataSource>();
@Module({
  imports: [
    TypeOrmModule.forRootAsync({
      useClass: TypeOrmConfigService,
      dataSourceFactory: async (options) => {
        if (!options) {
          throw new Error('TypeORM DataSourceOptions is not defined');
        }
        const tenantKey = (options as Record<string, any>).tenantId || '1';
        const cachedDataSource = dataSources.get(tenantKey);
        if (cachedDataSource) {
          return cachedDataSource;
        }

        const dataSource = await new DataSource(options).initialize();
        dataSources.set(tenantKey, dataSource);
        return dataSource;
      },
    }),
  ],
})
export class TypeormCommonModule implements OnApplicationShutdown {
  constructor() {}
  async onApplicationShutdown(signal: string) {
    for (const [key, dataSource] of dataSources) {
      if (dataSource.isInitialized) {
        console.log('closing', key);
        await dataSource.destroy();
      }
    }
  }
}
