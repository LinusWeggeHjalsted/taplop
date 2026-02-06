using UnityEngine;
using System.Collections.Generic;
using System.Linq;

public class FlashStrikeScript : MonoBehaviour, Skill
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private int duration;
    private int cooldown;
    private Sprite skillSprite;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    private int _skillBarPosition;
    public int skillBarPosition
    {
        get
        {
            return _skillBarPosition;
        }
        set
        {
            _skillBarPosition = value;
        }
    }

    public string GetSkillName()
    {
        return skillName;
    }

    public string GetSkillType()
    {
        return skillType;
    }

    public string GetDescription()
    {
        return description;
    }

    public float GetRange()
    {
        return range;
    }

    public int GetDuration()
    {
        return duration;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int GetCooldown()
    {
        return cooldown;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        if (enemyScript.GetSkillCooldown(skillName) > 0)
        {
            return -1;
        }
        else
        {
            return 2;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy)
    {
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        float effectiveRange = range + enemyScript.enchantmentModifiers.range;
        Dictionary<Vector3, GameObject> highlightedTileLookup = traversableTilesScript.highlightedTileLookup;
        List<Vector3> targetPositions = new List<Vector3>();
        foreach (Vector3 targetPosition in highlightedTileLookup.Keys)
        {
            if (traversableTilesScript.Distance(fromPosition, targetPosition) <= effectiveRange)
            {
                targetPositions.Add(targetPosition);
            }
        }
        // sort targetPositions by distance to player
        // use walking distance when path exists, otherwise fall back to straight-line distance
        targetPositions = targetPositions.OrderBy(pos => {
            float walkingDist = traversableTilesScript.WalkingDistance(pos, player.transform.position);
            if (walkingDist == float.MaxValue)
            {
                return traversableTilesScript.Distance(pos, player.transform.position);
            }
            else
            {
                return walkingDist;
            }
        }).ToList();
        return targetPositions[0];
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.DisplayUsedSkill(skillSprite);
        wielderScript.MoveTo(targetPosition);
        // moving can end the level in which case we stop
        if (player == null)
        {
            return;
        }
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -1; i <= 1; i++)
        {
            for (float j = -1; j <= 1; j++)
            {
                if (i == 0 && j == 0)
                {
                    continue;
                }
                else
                {
                    Vector3 delta = new Vector3(i, j, 0);
                    deltas.Add(delta);
                }
            }
        }
        foreach (Vector3 delta in deltas)
        {
            Vector3 attackTarget = targetPosition + delta;
            Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
            GameObject target = null;
            if (targetPosition == player.transform.position)
            {
                if (enemyLookup.ContainsKey(attackTarget))
                {
                    target = enemyLookup[attackTarget];
                }
            }
            if (enemyLookup.ContainsKey(targetPosition))
            {
                if (attackTarget == player.transform.position)
                {
                    target = player;
                }
            }
            if (target != null)
            {
                wielderScript.Attack(wielderScript.offHandDamage, target);
            }
        }
        wielderScript.SetSkillCooldown(skillName, cooldown);
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
        }
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        float effectiveRange = range + wielderScript.enchantmentModifiers.range;
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -effectiveRange; i <= effectiveRange; i++)
        {
            for (float j = -effectiveRange; j <= effectiveRange; j++)
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
            Vector3 targetPosition = fromPosition + delta;
            if (tileLookup.ContainsKey(targetPosition))
            {
                GameObject targetTile = tileLookup[targetPosition];
                TileScript targetTileScript = targetTile.GetComponent<TileScript>();
                if (!targetTileScript.isOccupied)
                {
                    targetTileScript.IsHighlighted = true;
                }
                else if (targetPosition == fromPosition)
                {
                    targetTileScript.IsHighlighted = true;
                }
            }
        }
    }

    void Start()
    {
        skillName = "Flash Strike";
        skillType = "Off Hand Skill";
        description = "Teleport then attack each adjacent target";
        range = 3f;
        duration = 0;
        cooldown = 3;
        skillSprite = Resources.Load<Sprite>("Skills/FlashStrike");
        traversableTiles = GameObject.Find("Traversable Tiles");
        if (traversableTiles != null)
        {
            traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        }
        enemies = GameObject.Find("Enemies");
        if (enemies != null)
        {
            enemiesScript = enemies.GetComponent<EnemiesScript>();
        }
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        }
    }
}
