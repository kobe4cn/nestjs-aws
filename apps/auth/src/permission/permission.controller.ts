import {
  Controller,
  Get,
  Post,
  Body,
  Patch,
  Param,
  Delete,
  Query,
} from '@nestjs/common';
import { PermissionService } from './permission.service';
import {
  type CreatePermissionDto,
  createPermissionSchema,
} from './dto/create-permission.dto';
import {
  type UpdatePermissionDto,
  updatePermissionSchema,
} from './dto/update-permission.dto';

@Controller('permission')
export class PermissionController {
  constructor(private readonly permissionService: PermissionService) {}

  @Post()
  create(
    @Body({ schema: createPermissionSchema })
    createPermissionDto: CreatePermissionDto,
  ) {
    return this.permissionService.create(createPermissionDto);
  }

  @Get()
  findAll(@Query() query: { page: number; limit: number }) {
    return this.permissionService.findAll(query.page, query.limit);
  }

  @Get(':id')
  findOne(@Param('id') id: string) {
    return this.permissionService.findOne(+id);
  }

  @Patch(':id')
  update(
    @Param('id') id: string,
    @Body({ schema: updatePermissionSchema })
    updatePermissionDto: UpdatePermissionDto,
  ) {
    return this.permissionService.update(+id, updatePermissionDto);
  }

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.permissionService.remove(+id);
  }
}
