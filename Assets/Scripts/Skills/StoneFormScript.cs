using UnityEngine;

public class StoneFormScript : MonoBehaviour, Skill, EnchantmentScript
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private int duration;
    private int cooldown;
    private int currentCooldown = 0;
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

    public int GetCooldown()
    {
        return cooldown;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        if (currentCooldown > 0)
        {
            return -1;
        }
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        if (enemyScript.CurrentHealth < enemyScript.MaxHealth)
        {
            return 0;
        }
        else
        {
            return -1;
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
        wielderScript.DisplayUsedSkill(skillSprite);
        // create or extend enchantment
        Transform wielderEnchantments = wielderScript.enchantments;
        GameObject stoneFormEnchantment;
        Transform stoneFormTransform = wielderEnchantments.Find("Stone Form");
        if (stoneFormTransform != null)
        {
            stoneFormEnchantment = stoneFormTransform.gameObject;
        }
        else
        {
            GameObject stoneFormPrefab = Resources.Load<GameObject>("Prefabs/Stone Form");
            stoneFormEnchantment = Instantiate(stoneFormPrefab, wielderEnchantments);
            stoneFormEnchantment.name = "Stone Form";
        }
        EnchantmentScript enchantmentScript = stoneFormEnchantment.GetComponent<EnchantmentScript>();
        int effectiveDuration = duration + wielderScript.enchantmentModifiers.duration;
        enchantmentScript.currentDuration += effectiveDuration;
        currentCooldown = cooldown;
    }

    // enchantment functions
    private int _currentDuration = 0;
    public int currentDuration
    {
        get
        {
            return _currentDuration;
        }
        set
        {
            _currentDuration = value;
            if (_currentDuration <= 0)
            {
                _currentDuration = 0;
            }
        }
    }

    public EntityScript.Modifiers ModifierEffects()
    {
        EntityScript.Modifiers modifiers = new EntityScript.Modifiers();
        modifiers.outgoingStunDuration = 1;
        modifiers.incomingStunDuration = -1;
        return modifiers;
    }

    public void OnAttackEffect(GameObject target, GameObject wielder)
    {
    }

    public void EndOfTurnEffect(GameObject wielder)
    {
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.CurrentHealth += wielderScript.MaxHealth / 5;
    }

    public void EndEffect(GameObject wielder)
    {
    }

    void Start()
    {
        skillName = "Stone Form";
        skillType = "Enchantment";
        description = "Reduce incoming stun durations by 1, increase outgoing stun durations by 1, and heal 20% of max health at end of turn";
        range = 0;
        duration = 5;
        cooldown = 10;
        skillSprite = Resources.Load<Sprite>("Skills/StoneForm");
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
