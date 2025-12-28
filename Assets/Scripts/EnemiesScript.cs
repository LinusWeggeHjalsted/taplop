using UnityEngine;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class EnemiesScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject player;
    public Dictionary<Vector3, GameObject> tileLookup = new Dictionary<Vector3, GameObject>();
    public Dictionary<Vector3, GameObject> enemyLookup = new Dictionary<Vector3, GameObject>();
    public Dictionary<Vector3, GameObject> activeEnemyLookup = new Dictionary<Vector3, GameObject>();

    IEnumerator WaitForLevelBuilderBeforePopulating()
    {
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        while (!traversableTilesScript.finishedBuilding)
        {
            yield return null;
        }
        tileLookup = traversableTilesScript.tileLookup;
        // populate enemyLookup
        for (int i = 0; i < this.transform.childCount; i++)
        {
            Transform enemyTransform = this.transform.GetChild(i);
            GameObject enemy = enemyTransform.gameObject;
            enemyLookup.Add(enemyTransform.position, enemy);
            GameObject tile = tileLookup[enemyTransform.position];
            TileScript tileScript = tile.GetComponent<TileScript>();
            tileScript.isOccupied = true;
        }
        finishedBuilding = true;
    }

    void Start()
    {
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        player = GameObject.Find("Player");
        // wait for level builder
        StartCoroutine(WaitForLevelBuilderBeforePopulating());
    }

    public void FillEnemyHealth()
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject enemy = this.transform.GetChild(i).gameObject;
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            enemyScript.CurrentHealth = enemyScript.MaxHealth;
        }
    }

    public void UpdateAggro()
    {
        foreach (GameObject enemy in enemyLookup.Values)
        {
            // to-do: deaggro when player is far away
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            if (!enemyScript.IsActive)
            {
                Vector3 playerPosition = player.transform.position;
                Vector3 enemyPosition = enemy.transform.position;
                int aggroRange = enemyScript.aggroRange;
                if (traversableTilesScript.Distance(playerPosition, enemyPosition) <= (float)aggroRange)
                {
                    enemyScript.IsActive = true;
                }
            }
        }
    }

    public void EnemyMoved(Vector3 currentPosition, Vector3 targetPosition)
    {
        GameObject enemyObject = enemyLookup[currentPosition];
        enemyLookup.Add(targetPosition, enemyObject);
        enemyLookup.Remove(currentPosition);
        if (activeEnemyLookup.ContainsKey(currentPosition))
        {
            activeEnemyLookup.Add(targetPosition, enemyObject);
            activeEnemyLookup.Remove(currentPosition);
        }
    }

    public void KillDeadEnemies()
    {
        List<GameObject> enemyObjects = enemyLookup.Values.ToList();
        foreach (GameObject enemy in enemyObjects)
        {
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            if (enemyScript.CurrentHealth <= 0)
            {
                enemyScript.DropItems();
                Vector3 enemyPosition = enemy.transform.position;
                enemyLookup.Remove(enemyPosition);
                if (activeEnemyLookup.ContainsKey(enemyPosition))
                {
                    activeEnemyLookup.Remove(enemyPosition);
                }
                GameObject tile = tileLookup[enemyPosition];
                TileScript tileScript = tile.GetComponent<TileScript>();
                tileScript.isOccupied = false;
                Destroy(enemy);
                PlayerDataScript.Instance.defeatedEnemies += 1;
                MissionLogicScript.Instance.totalKills += 1;
            }
        }
    }

    public void EnemyTurnMove(GameObject enemy)
    {
        Vector3 enemyPosition = enemy.transform.position;
        Vector3 playerPosition = player.transform.position;
        float distanceToPlayer = traversableTilesScript.Distance(enemyPosition, playerPosition);
        List<Vector3> pathToPlayer = traversableTilesScript.ShortestPath(enemyPosition, playerPosition);
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        int enemySpeed = enemyScript.Speed;
        float enemyMinRange = enemyScript.minRange;
        if (distanceToPlayer <= enemyMinRange)
        {
            return;
        }
        if (pathToPlayer != null)
        {
            int pathLength = pathToPlayer.Count;
            // go as far as it can, but stop short of player
            Vector3 targetPosition = playerPosition;
            if (pathLength > 1)
            {
                // pathToPlayer is sorted in reverse order
                if (enemySpeed >= pathLength - 1)
                {
                    targetPosition = pathToPlayer[1];
                }
                else
                {
                    // (pathLength - 1) - (enemySpeed - 1)
                    targetPosition = pathToPlayer[pathLength - enemySpeed];
                }
                enemyScript.MoveTo(targetPosition);
            }
        }
        else
        {
            if (distanceToPlayer <= enemyMinRange)
            {
                return;
            }
            Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
            List<Vector3> deltas = new List<Vector3>();
            for (float i = -enemySpeed; i <= enemySpeed; i++)
            {
                for (float j = -enemySpeed; j <= enemySpeed; j++)
                {
                    if (i == 0 && j == 0)
                    {
                        continue;
                    }
                    Vector3 delta = new Vector3(i, j, 0);
                    deltas.Add(delta);
                }
            }
            List<Vector3> targetPositions = new List<Vector3>();
            foreach (Vector3 delta in deltas)
            {
                Vector3 targetPosition = enemyPosition + delta;
                if (!tileLookup.ContainsKey(targetPosition))
                {
                    continue;
                }
                else
                {
                    GameObject targetTile = tileLookup[targetPosition];
                    TileScript targetTileScript = targetTile.GetComponent<TileScript>();
                    List<Vector3> pathToTarget = traversableTilesScript.ShortestPath(enemyPosition, targetPosition);
                    if (pathToTarget != null && pathToTarget.Count <= enemySpeed)
                    {
                        targetPositions.Add(targetPosition);
                    }
                }
            }
            if (targetPositions.Count > 0)
            {
                // sort targetPositions by distance to player
                targetPositions = targetPositions.OrderBy(pos => traversableTilesScript.Distance(pos, player.transform.position)).ToList();
                enemyScript.MoveTo(targetPositions[0]);
            }
        }
    }

    public IEnumerator EnemyTurnAttack(GameObject enemy)
    {
        Vector3 enemyPosition = enemy.transform.position;
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        GameObject[] enemySkills = enemyScript.equippedSkills;
        Dictionary<GameObject, int> attackSkillPriorities = new Dictionary<GameObject, int>();
        List<GameObject> priority0Skills = new List<GameObject>();
        for (int i = 0; i < enemySkills.Length; i++)
        {
            GameObject skill = enemySkills[i];
            if (skill != null)
            {
                Skill skillScript = skill.GetComponent<Skill>();
                int enemyPriority = skillScript.EnemyPriority(enemyPosition, enemy);
                if (enemyPriority == 0)
                {
                    priority0Skills.Add(skill);
                }
                else if (enemyPriority > 0)
                {
                    attackSkillPriorities.Add(skill, enemyPriority);
                }
            }
        }
        List<KeyValuePair<GameObject, int>> sortedSkillPriorities = new List<KeyValuePair<GameObject, int>>();
        sortedSkillPriorities = attackSkillPriorities.OrderBy(pair => pair.Value).ToList();
        // if there are any priority 0 skills left to cast, cast one and restart attack turn
        if (priority0Skills.Count > 0)
        {
            GameObject skill = priority0Skills[0];
            Skill skillScript = skill.GetComponent<Skill>();
            skillScript.PrepareSkill(enemyPosition, enemy);
            Vector3 selectedTarget = skillScript.EnemySelectTarget(enemyPosition, enemy);
            skillScript.UseSkill(selectedTarget, enemy);
            KillDeadEnemies();
            yield return new WaitForSeconds(0.5f);
            yield return EnemyTurnAttack(enemy);
        }
        // then use an attack
        else if (sortedSkillPriorities.Count > 0)
        {
            GameObject selectedAttack = sortedSkillPriorities[0].Key;
            Skill attackScript = selectedAttack.GetComponent<Skill>();
            attackScript.PrepareSkill(enemyPosition, enemy);
            Vector3 attackTarget = attackScript.EnemySelectTarget(enemyPosition, enemy);
            attackScript.UseSkill(attackTarget, enemy);
            KillDeadEnemies();
        }
    }
}
