import { Module } from '@nestjs/common';
import { TypeormCommonModule } from './typeorm/typeorm-common.module';

@Module({
  imports: [TypeormCommonModule],
})
export class DatabaseModule {}
