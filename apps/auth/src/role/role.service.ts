import { Injectable } from '@nestjs/common';
import { CreateRoleDto } from './dto/create-role.dto';
import { UpdateRoleDto } from './dto/update-role.dto';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Role } from '@app/common/database/typeorm/entity/role.entity';

@Injectable()
export class RoleService {
  constructor(
    @InjectRepository(Role)
    private readonly roleRepository: Repository<Role>,
  ) {}

  create(createRoleDto: CreateRoleDto) {
    const DEFAULT_PERMISSION_ID = 1;
    const { rolePermission, ...roleData } = createRoleDto;
    const rolePermissionIds = rolePermission || [DEFAULT_PERMISSION_ID];
    return this.roleRepository.save({
      ...roleData,
      rolePermission: rolePermissionIds.map((permissionId) => ({
        permissionId,
      })),
    });
  }

  findAll(page: number, limit: number) {
    const skip = (page - 1) * limit;
    return this.roleRepository.findAndCount({ skip, take: limit });
  }

  findOne(id: number) {
    return this.roleRepository.findOne({
      where: { id },
      relations: {
        rolePermission: true,
      },
    });
  }

  update(id: number, updateRoleDto: UpdateRoleDto) {
    return this.roleRepository.update({ id }, updateRoleDto, {
      returning: ['name', 'description'],
    });
  }

  remove(id: number) {
    return this.roleRepository.delete({ id });
  }
}
