import { Injectable } from '@nestjs/common';
import { CreatePermissionDto } from './dto/create-permission.dto';
import { UpdatePermissionDto } from './dto/update-permission.dto';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Permission } from '@app/common/database/typeorm/entity/permission.entity';

@Injectable()
export class PermissionService {
  constructor(
    @InjectRepository(Permission)
    private readonly permRepo: Repository<Permission>,
  ) {}
  create(createPermissionDto: CreatePermissionDto) {
    return this.permRepo.save(createPermissionDto);
  }

  findAll(page: number, limit: number) {
    const skip = (page - 1) * limit;
    return this.permRepo.findAndCount({
      skip,
      take: limit,
    });
  }

  findOne(id: number) {
    return this.permRepo.findOne({ where: { id } });
  }

  update(id: number, updatePermissionDto: UpdatePermissionDto) {
    return this.permRepo.update(id, updatePermissionDto);
  }

  remove(id: number) {
    return this.permRepo.delete(id);
  }
}
