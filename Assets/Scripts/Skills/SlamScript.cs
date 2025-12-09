using UnityEngine;
using System.Collections.Generic;

public class SlamScript : MonoBehaviour, Skill
{
    private string skillName;
    private string skillType;
    private string description; 
    private float range;
    private int duration;
    private int cooldown;
    private Sprite skillSprite;
    public GameObject sword;
    public SwordScript swordScript;
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
        float effectiveRange = range + enemyScript.enchantmentModifiers.range;
        Vector3 playerPosition = player.transform.position;
        float distanceToPlayer = traversableTilesScript.Distance(fromPosition, playerPosition);
        if (distanceToPlayer > effectiveRange)
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
        float effectiveRange = range + wielderScript.enchantmentModifiers.range;
        wielderScript.DisplayUsedSkill(skillSprite);
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
                targetScript.Knockback(fromPosition, wielder, 2 * wielderScript.mainHandDamage);
                int outgoingModifier = wielderScript.enchantmentModifiers.outgoingStunDuration;
                int incomingModifier = targetScript.enchantmentModifiers.incomingStunDuration;
                int effectiveDuration = duration + outgoingModifier + incomingModifier;
                targetScript.stunDuration += effectiveDuration;
            }
        }
        wielderScript.SetSkillCooldown(skillName, cooldown);
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
        }
    }

    void Start()
    {
        skillName = "Slam";
        skillType = "Main Hand Skill";
        description = "Stun and knockback each target within range";
        range = 1f;
        duration = 1;
        cooldown = 3;
        skillSprite = Resources.Load<Sprite>("Skills/Slam");
        sword = this.transform.parent.gameObject;
        swordScript = sword.GetComponent<SwordScript>();
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
