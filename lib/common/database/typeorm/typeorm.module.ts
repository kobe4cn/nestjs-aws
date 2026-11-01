import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { TypeOrmConfigService } from './typeorm.service';
import { DataSource } from 'typeorm';
import { TypeOrmShutDownService } from './typeorm.shutdown';
import { TypeormCommonModule } from './typeorm-common.module';
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
    TypeormCommonModule,
  ],
  providers: [
    TypeOrmShutDownService,
    { provide: 'TYPEORM_DATASOURCE', useValue: dataSources },
  ],
})
export class TypeormModule  {}
