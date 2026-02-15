using UnityEngine;
using System;
using System.Collections.Generic;

public class SlamScript : MonoBehaviour, SkillScript
{
    private string skillName;
    private string skillType;
    private string description; 
    private float range;
    private float radius;
    private float distance;
    private int skillDuration;
    private int stunDuration;
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

    public float GetRadius()
    {
        return radius;
    }

    public float GetDistance()
    {
        return distance;
    }

    public int GetSkillDuration()
    {
        return skillDuration;
    }

    public int GetStunDuration()
    {
        return stunDuration;
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
        float effectiveRadius = radius + enemyScript.enchantmentModifiers.radius;
        Vector3 playerPosition = player.transform.position;
        float distanceToPlayer = traversableTilesScript.Distance(fromPosition, playerPosition);
        if (distanceToPlayer > effectiveRadius)
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
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        float effectiveRadius = radius + wielderScript.enchantmentModifiers.radius;
        wielderScript.DisplayUsedSkill(skillSprite);
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -effectiveRadius; i <= effectiveRadius; i++)
        {
            for (float j = -effectiveRadius; j <= effectiveRadius; j++)
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
            Vector3 targetPosition = fromPosition + delta;
            Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
            GameObject target = null;
            if (fromPosition == player.transform.position)
            {
                if (enemyLookup.ContainsKey(targetPosition))
                {
                    target = enemyLookup[targetPosition];
                }
            }
            if (enemyLookup.ContainsKey(fromPosition))
            {
                if (targetPosition == player.transform.position)
                {
                    target = player;
                }
            }
            if (target != null)
            {
                EntityScript targetScript = target.GetComponent<EntityScript>();
                float preciseDamage = 1.5f * (float)wielderScript.mainHandDamage;
                float effectiveDistance = distance + wielderScript.enchantmentModifiers.distance;
                targetScript.Knockback(fromPosition, wielder, (int)preciseDamage, effectiveDistance);
                int outgoingModifier = wielderScript.enchantmentModifiers.outgoingStunDuration;
                int incomingModifier = targetScript.enchantmentModifiers.incomingStunDuration;
                int effectiveStunDuration = stunDuration + outgoingModifier + incomingModifier;
                targetScript.stunDuration = Math.Max(effectiveStunDuration, targetScript.stunDuration);
            }
        }
        wielderScript.SetSkillCooldown(skillName, cooldown);
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
            turnLogicScript.hasUsedAnySkill = true;
        }
    }

    void Awake()
    {
        skillName = "Slam";
        skillType = "Main Hand Skill";
        description = "Knockback and stun each target within radius, dealing 1.5x damage to targets on collision";
        range = 0;
        radius = 1;
        distance = 2;
        skillDuration = 0;
        stunDuration = 1;
        cooldown = 3;
        skillSprite = Resources.Load<Sprite>("Skills/Slam");
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            traversableTiles = LevelScript.Instance.traversableTiles;
            traversableTilesScript = LevelScript.Instance.traversableTilesScript;
            enemies = LevelScript.Instance.enemies;
            enemiesScript = LevelScript.Instance.enemiesScript;
            player = LevelScript.Instance.player;
            turnLogic = LevelScript.Instance.turnLogic;
            turnLogicScript = LevelScript.Instance.turnLogicScript;
        }
    }
}
