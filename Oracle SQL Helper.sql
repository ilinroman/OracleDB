-----------------------------------
-- ВОССТАНОВЛЕНИЕ ДАННЫХ ТАБЛИЦЫ --
-----------------------------------
--Максимальное время хранения данных для восстановления в минутах (по умолчанию 1440 мин = 24 часа)
select * from V$PARAMETER where name = 'db_flashback_retention_target';
--Просмотр текущей мметки SCN
select dbms_flashback.get_system_change_number from dual;
--Запрос данных на заданный момент времени
select *
from t as of scn :scn;
--или
select * 
from t as of timestamp to_timestamp('2017-08-28 01:00:00', 'YYYY-MM-DD HH24:MI:SS');
--Восстановление
--1. разрешение на перемещение строк в БД
alter table t enable row movement;
--2. восстановление состояния таблицы к метке scn
flashback table t to scn :scn;

-----------------
-- ПАРАЛЛЕЛИЗМ --
-----------------
--SID текущего сеанса
select sid from v$mystat where rownum = 1;
--или
select sys_context('userenv','sid') from dual;

--Проверка активации PDML (параллельное выполнение операции DML - INSERT, UPDATE, DELETE. MERGE)
select pdml_enabled from v$session where sid= sys_context('userenv','sid');

--Активация режима параллелизма DML
alter session enable parallel dml;
/*
  в качестве альтернативы можно использовать хинт ENABLE_PARALLEL_DML непосредственно в DML
*/

--Список параллельных сессий м транзакций
select a.sid, a.program, b.start_time, b.used_ublk,
b.xidusn ||'.'|| b.xidslot || '.' || b.xidsqn trans_id
from v$session a, v$transaction b
where a.taddr = b.addr
and a.sid in ( select sid
from v$px_session
where qcsid = 258)
order by sid; 

--Тип и количество параллельных действий
select name, value from v$statname a, v$mystat b
where a.statistic# = b.statistic# and name like '%parallel%';

------------------
-- ПЛАН ЗАПРОСА --
------------------

--Получение плана запроса
--Способ 1. Предполагаемый план (explain plan)
delete from plan_table;
explain plan for 
  [SQL запрос]; --можно с bind'ами
--получение результата
select lpad(' ', 2 * (level - 1)) || operation || '  ' || options || '  ' ||
       object_name plan,
       pt.*
  from plan_table pt
 start with id = 0
connect by prior id = parent_id;
--ИЛИ
select * from table(dbms_xplan.display);
--Способ 2. Реальный план (execute plan)
select * from v$sql_plan where sql_id = 'dwmhrx903p9w0';
--Способ 3. Реальный план курсора (тянется из кэша курсоров)
select s.sql_id, plan_table_output
from v$sql s,
table(dbms_xplan.display_cursor(s.sql_id,
                                s.child_number, 'basic +PEEKED_BINDS')) t
where s.sql_text like 'UPDATE SIEBEL.S_CONTACT%';

--Значения входных параметров (bind) запроса
select s.SQL_TEXT, s.FIRST_LOAD_TIME, b.*
from v$sql s,
     v$sql_bind_capture b
where s.ADDRESS = b.ADDRESS and
      s.SQL_TEXT like 'UPDATE%CONTACT_ID%'
      --s.SQL_ID = 'dwmhrx903p9w0'

--Очистка библиотечного кэша
--подчищает планы запросов
alter system flush shared_pool;
--точечное удаление плана запроса
declare
  v_addr_hash varchar2(100);
begin
  select ADDRESS ||','||HASH_VALUE into v_addr_hash from v$sql where SQL_ID = 'dwmhrx903p9w0';
  sys.dbms_shared_pool.purge(v_addr_hash, 'C');
/*
  Фактически удалется запись из v$sqlarea.
  Иногда может не срабатывать из-за бага 11829677 Child cursors with is_shareable=n are not purged by dbms_shared_pool.purge
*/
end;

-- Реальный план курсора (тянется из кэша курсоров)
select s.sql_id, plan_table_output
from v$sql s,
table(dbms_xplan.display_cursor(s.sql_id,
                                s.child_number, 'basic +PEEKED_BINDS')) t
where s.sql_text like 'insert /*+ parallel(2) */%';

----------------------------
-- УПРАВЛЕНИЕ СТАТИСТИКОЙ --
----------------------------

--Переопределение статистики для таблицы
begin dbms_stats.set_table_stats(ownname => 'SIEBEL', tabname => 'EIM_LEAD', numrows => 100000000); end;
--то же самое для индекса 
begin dbms_stats.set_index_stats(ownname => 'SIEBEL', indname => 'EIM_LEAD_U1', numrows => 100000); end;
/*
  Используется исключительно для ТЕСТА! Позволяется явно указать количество строк в таблице или индексе
*/

-- Дефрагментация таблицы --
--Расчет размера таблицы
SELECT TABLE_NAME,
       ROUND((BLOCKS*8)/1024) AS "Total Size, Mb",              --общий размер таблицы
       ROUND(NUM_ROWS*AVG_ROW_LEN/1024/1024) AS "Real Size, Mb" --реальный размер данных в таблице
  FROM USER_TABLES
 WHERE TABLE_NAME = 'S_ORDER';
/* 
  Если общий размер таблицы в разы больше реального размера, то необходима дефрагментация таблицы
*/
--Дефрагментация
ALTER TABLE S_ORDER move nologging;

-- Сбор статистики по таблице и индексу --
/* 
 Перед сбором статистики необходимо удостовериться, что сбор статистики не заблокирован на уровне БД
*/
--Просмотр наличия блокировки статистики 
SELECT OWNER, TABLE_NAME, LAST_ANALYZED, 
       STATTYPE_LOCKED --если not null (например, ALL), то на таблице блокировка сбора статистики
FROM ALL_tab_STATISTICS D WHERE OWNER = 'SIEBEL' AND TABLE_NAME = 'EIM_LEAD';
--Блокировка статистики
begin dbms_stats.lock_table_stats('SIEBEL', 'EIM_LEAD'); end;
--Разблокировка статистики
begin dbms_stats.unlock_table_stats('SIEBEL', 'EIM_LEAD'); end;

--Вычисление процента сбора статистики
--по таблице
SELECT owner,
       table_name,
       num_rows,
       degree,
       round(d.sample_size /
             decode(d.num_rows, 0, 100000000000, d.num_rows) * 100,
             2) proch, --процент сбора статистики
       d.last_analyzed --дата и время последнего сбора статистики
  FROM dba_tables d
 WHERE owner = 'SIEBEL'
   and table_name = 'S_ORDER';
--по индексу
SELECT owner,
       table_name,
       index_name,
	   num_rows,
       round(sample_size * 100 /
             nvl(decode(num_rows, 0, 100000, num_rows), 1000000),
             2) proch, --процент сбора статистики
       last_analyzed   --дата и время последнего сбора статистики
  FROM ALL_IND_STATISTICS D
 Where owner = 'SIEBEL'
   and table_name = 'S_ORDER';

--Cбор статистики
begin
--по таблице
  DBMS_STATS.GATHER_TABLE_STATS('SIEBEL', 'S_ORDER');
  --ИЛИ
  --DBMS_STATS.GATHER_TABLE_STATS('SIEBEL','S_ORDER',NULL,10,NULL,'FOR ALL INDEXED COLUMNS SIZE AUTO',4);
--по индексу
  --DBMS_STATS.GATHER_INDEX_STATS('SIEBEL', 'S_CONTACT_P1');
  FOR i IN (SELECT INDEX_NAME FROM USER_INDEXES WHERE TABLE_NAME = 'S_ORDER') LOOP
    DBMS_STATS.GATHER_INDEX_STATS('SIEBEL', i.INDEX_NAME);
  END LOOP;
  --ИЛИ
  --DBMS_STATS.GATHER_INDEX_STATS('HIST','X_AGREEMENT',null,10,null,null,4);
  --FOR i IN (SELECT INDEX_NAME FROM USER_INDEXES WHERE TABLE_NAME = 'S_ORDER') LOOP
  --  DBMS_STATS.GATHER_INDEX_STATS('SIEBEL', i.INDEX_NAME, null, 10, null, null, 4);
  --END LOOP;
end;
/*
  где число 10 в процедуре указывает на процент сбора статистики. 
  С учетом времени сбора статистики и числа строк в таблице (индексе) были выработаны рекомендации для таблиц (индексов) по проценту сбора статистики: 
  если число строк более 100 млн. процент сбора устанавливать 2-5, 
  при числе строк с 10 млн. до 100 млн. процент сбора устанавливать 5-10, 
  менее 10 млн. процент сбора устанавливать 20-100. 
  При этом, чем выше процент сбора, тем лучше, однако, при этом растет и может быть существенным время сбора статистики!
*/

-- Проверка фактора кластеризации индекса --
--Фактор кластеризации индекса
Select I.OWNER,
       T.TABLE_NAME,
       I.INDEX_NAME,
       T.LAST_ANALYZED,
       T.BLOCKS,              --кол-во блоков таблицы (минимальное значение фактора)
       I.CLUSTERING_FACTOR,   --фактор кластеризации
       I.NUM_ROWS I_NUM_ROWS, --кол-во строк в индексе (минимальное значение фактора)
       t.NUM_ROWS T_NUM_ROWS  --кол-во строк в таблице
  from ALL_INDEXES I, ALL_TABLES T
 where I.table_name = T.table_name
   and I.owner = T.owner
   and I.owner = 'SIEBEL'
   --and I.index_name = 'EIM_LEAD_U1'
   and T.TABLE_NAME = 'S_ORDER';
--Статистика и статус индексов
select index_name,
       table_name,
       num_rows,
       sample_size,
       distinct_keys,
       last_analyzed,
       STATUS, i.*
  from all_indexes i
 where table_owner = 'SIEBEL'
   and table_name = 'S_ORDER';
/*
  Фактор кластеризации для индекса считается во время сбора статистики.
  Если CLUSTERING_FACTOR стремится к BLOCKS - это нормально, а если CLUSTERING_FACTOR стремится к I_NUM_ROWS - это говорит о неэффективном индексе.
  Первое решение при большом ФК является убрать существующий индекс как не эффективный. 
  Второе решение, если данный индекс наиболее часто применяется в запросах и он нужен, то перестроить структуру таблицы таким образом, чтобы строки в блоках таблицы были упорядочены в том же порядке, в котором расположена информация по данным строкам в индексе, т.е. сделать кластерными блоки таблицы, уменьшив таким образом число перемещений от одного блока к другому при работе индекса.
*/
--Перестроение индекса
--единичной командой
ALTER INDEX S_CONTACT_P1 rebuild ONLINE nologging;
--в цикле
BEGIN
  FOR i IN (SELECT INDEX_NAME FROM USER_INDEXES WHERE TABLE_NAME = 'S_ORDER') LOOP
    EXECUTE IMMEDIATE 'ALTER INDEX ' || i.INDEX_NAME || ' rebuild ONLINE nologging';
  END LOOP;
END;

------------
-- ДРУГОЕ --
------------

--Просмотр значения параметра
select * from V$PARAMETER where upper(name) = 'CONTROL_MANAGEMENT_PACK_ACCESS';
